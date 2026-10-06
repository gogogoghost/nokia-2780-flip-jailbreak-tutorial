/// Backends used by the Sideload service.
///
/// * `apps_uds_call` talks to the api-daemon apps service over its UDS
///   (`/data/local/tmp/apps-uds.sock`), the very same interface `appscmd`
///   uses. It carries `install`, `install-pwa`, `uninstall`, `list` and
///   `ready` commands, and answers one JSON line per request:
///   `{"name": <cmd>, "success": <str>}` or `{"name": <cmd>, "error": <str>}`.
///
/// * `vhost_get` reads a file from an installed application through the
///   api-daemon vhost (`http://127.0.0.1` plus a `Host: <origin>` header).
///   This replaces the legacy HTTP `/proxy/<host>/<path>` endpoint.
use flate2::read::{DeflateDecoder, GzDecoder, ZlibDecoder};
use serde_json::{json, Value};
use std::io::{Read, Write};
use std::os::unix::net::UnixStream;
use std::time::Duration;

/// Path of the apps service UDS, overridable for testing.
pub const DEFAULT_APPS_UDS: &str = "/data/local/tmp/apps-uds.sock";
/// Base URL of the api-daemon HTTP/vhost server.
pub const DEFAULT_VHOST: &str = "http://127.0.0.1:80";
/// Upper bound for any payload read from a backend.
pub const MAX_PAYLOAD: usize = 64 * 1024 * 1024;

fn apps_uds_path() -> String {
    std::env::var("SIDELOAD_APPS_UDS").unwrap_or_else(|_| DEFAULT_APPS_UDS.to_string())
}

fn vhost_base() -> String {
    std::env::var("SIDELOAD_VHOST").unwrap_or_else(|_| DEFAULT_VHOST.to_string())
}

/// The vhost selects an application from the `Host` header, which must be a
/// bare host name: callers may pass either "ostore.localhost" or
/// "http://ostore.localhost" (the origin returned by the apps service).
fn normalize_host(origin: &str) -> String {
    let origin = origin.trim();
    let origin = origin
        .strip_prefix("http://")
        .or_else(|| origin.strip_prefix("https://"))
        .unwrap_or(origin);
    origin
        .split('/')
        .next()
        .unwrap_or(origin)
        .trim_end_matches('.')
        .to_string()
}

/// Runs one command on the apps service UDS and returns its `success` payload.
pub fn apps_uds_call(cmd: &str, param: Option<&str>) -> Result<String, String> {
    let path = apps_uds_path();
    let mut stream =
        UnixStream::connect(&path).map_err(|err| format!("connect {} failed: {}", path, err))?;
    let _ = stream.set_read_timeout(Some(Duration::from_secs(300)));
    let _ = stream.set_write_timeout(Some(Duration::from_secs(30)));

    let request = json!({
        "cmd": cmd,
        "param": param.map(Value::from).unwrap_or(Value::Null),
    });
    let body = request.to_string();
    stream
        .write_all(body.as_bytes())
        .and_then(|_| stream.write_all(b"\r\n"))
        .map_err(|err| format!("write to {} failed: {}", path, err))?;

    let mut buffer = Vec::new();
    let mut byte = [0u8; 1];
    loop {
        if buffer.len() > MAX_PAYLOAD {
            return Err(format!("apps service response for `{}` is too large", cmd));
        }
        match stream.read(&mut byte) {
            Ok(0) => break,
            Ok(_) => {
                buffer.push(byte[0]);
                if buffer.ends_with(b"\r\n") {
                    break;
                }
            }
            Err(err) => return Err(format!("read from {} failed: {}", path, err)),
        }
    }

    let payload = buffer.strip_suffix(b"\r\n").unwrap_or(&buffer);
    if payload.is_empty() {
        return Err(format!("empty response from apps service for `{}`", cmd));
    }
    let value: Value = serde_json::from_slice(payload)
        .map_err(|err| format!("invalid apps service response: {}", err))?;

    if let Some(error) = value.get("error").and_then(Value::as_str) {
        return Err(error.to_string());
    }
    match value.get("success").and_then(Value::as_str) {
        Some(success) => Ok(success.to_string()),
        None => Err(format!("unexpected apps service response: {}", value)),
    }
}

/// The vhost passes through the compression of the zip entry it serves
/// (`content-encoding: deflate` for most manifests and assets), and the daemon
/// compresses the static http_root files with gzip, so responses have to be
/// decoded here: the service hands plain bytes to its clients.
fn decode_body(bytes: Vec<u8>, encoding: Option<&str>) -> Result<Vec<u8>, String> {
    let encoding = encoding.unwrap_or("identity").trim().to_ascii_lowercase();
    match encoding.as_str() {
        "" | "identity" => Ok(bytes),
        "gzip" | "x-gzip" => inflate(GzDecoder::new(&bytes[..]), bytes.len(), "gzip"),
        "deflate" => {
            // HTTP "deflate" should be zlib, but the vhost forwards the raw
            // deflate stream stored in application.zip.
            match inflate(ZlibDecoder::new(&bytes[..]), bytes.len(), "zlib") {
                Ok(decoded) => Ok(decoded),
                Err(_) => inflate(DeflateDecoder::new(&bytes[..]), bytes.len(), "deflate"),
            }
        }
        other => Err(format!("unsupported content-encoding: {}", other)),
    }
}

fn inflate<R: Read>(mut reader: R, hint: usize, what: &str) -> Result<Vec<u8>, String> {
    let mut decoded = Vec::with_capacity(hint.saturating_mul(4));
    reader
        .read_to_end(&mut decoded)
        .map_err(|err| format!("{} decompression failed: {}", what, err))?;
    if decoded.len() > MAX_PAYLOAD {
        return Err(format!("{} payload is too large", what));
    }
    Ok(decoded)
}

/// Reads a file of an installed application from the api-daemon vhost.
pub fn vhost_get(origin: &str, path: &str) -> Result<Vec<u8>, String> {
    let base = vhost_base();
    let url = format!("{}/{}", base.trim_end_matches('/'), path.trim_start_matches('/'));
    let client = reqwest::blocking::Client::builder()
        .timeout(Duration::from_secs(300))
        .build()
        .map_err(|err| format!("http client creation failed: {}", err))?;
    let response = client
        .get(&url)
        .header("Host", normalize_host(origin))
        .send()
        .map_err(|err| format!("GET {} failed: {}", url, err))?;
    let status = response.status();
    if !status.is_success() {
        return Err(format!("GET {} -> {}", url, status.as_u16()));
    }
    let encoding = response
        .headers()
        .get(reqwest::header::CONTENT_ENCODING)
        .and_then(|value| value.to_str().ok())
        .map(|value| value.to_string());
    let bytes = response
        .bytes()
        .map_err(|err| format!("reading {} failed: {}", url, err))?;
    if bytes.len() > MAX_PAYLOAD {
        return Err(format!("{} is too large", url));
    }
    decode_body(bytes.to_vec(), encoding.as_deref())
        .map_err(|err| format!("{}: {}", url, err))
}

/// Splits an application URL into the vhost host and path: PWAs are served
/// under `cached.localhost/<name>/`, packaged apps under `<name>.localhost/`.
fn split_app_url(url: &str) -> (String, String) {
    let url = url.trim();
    let rest = url
        .strip_prefix("http://")
        .or_else(|| url.strip_prefix("https://"))
        .unwrap_or(url);
    match rest.split_once('/') {
        Some((host, path)) => (normalize_host(host), format!("/{}", path)),
        None => (normalize_host(rest), String::new()),
    }
}

/// Reads and parses the manifest of an installed application.
pub fn vhost_get_manifest(manifest_url: &str) -> Result<Value, String> {
    let (host, path) = split_app_url(manifest_url);

    // A bare origin means "the default manifest of this app".
    let candidates: Vec<String> = if path.is_empty() || path == "/" {
        vec!["/manifest.webmanifest".to_string(), "/manifest.webapp".to_string()]
    } else {
        vec![path]
    };

    let mut last_error = format!("no manifest found for {}", manifest_url);
    for candidate in candidates {
        match vhost_get(&host, &candidate) {
            Ok(bytes) => {
                return serde_json::from_slice(&bytes)
                    .map_err(|err| format!("invalid manifest {}: {}", candidate, err))
            }
            Err(err) => last_error = err,
        }
    }
    Err(last_error)
}
