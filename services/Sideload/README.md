# Sideload

Permission gated app management for KaiOS 3.1, exposed to applications as an
api-daemon remote service. It replaces the legacy `appscmd` HTTP daemon
(`127.0.0.1:5431`, no authentication) that OStore used to talk to.

Only applications whose token carries the **`sideload`** permission can create
the service (enforced by the daemon through the generated
`check_service_permission`, and re-checked per method). Sessions opened over the
api-daemon UDS (root tools) bypass permission checks, like every other service.

## API

| Method | Backend | Description |
|---|---|---|
| `list()` | apps UDS `list` | installed applications, same payload as `appscmd list` |
| `install(package_path)` | apps UDS `install` | install a packaged app from a device path |
| `install_pwa(manifest_url)` | apps UDS `install-pwa` | install a PWA |
| `uninstall(manifest_url)` | apps UDS `uninstall` | uninstall by manifest URL |
| `get_app_file(origin, path)` | vhost | raw file of an installed app (icons, ...) |
| `get_app_manifest(manifest_url)` | vhost | parsed manifest, resolved from the application manifest URL |
| `ready()` | apps UDS `ready` | whether the apps service backend is reachable |

All methods take/return plain types and report failures through the sidl error
channel (`-> T, str`), so clients receive the real backend error message.

### Backend notes

- **Apps service UDS** (`/data/local/tmp/apps-uds.sock`, overridable with
  `SIDELOAD_APPS_UDS`): one JSON line per request, `{"cmd": ..., "param": ...}`.
- **Vhost** (`http://127.0.0.1:80`, overridable with `SIDELOAD_VHOST`): the app
  is selected with a `Host` header. The service normalizes the origin
  (`http://ostore.localhost` and `ostore.localhost` both work) and decodes the
  response `Content-Encoding` (`deflate` — the vhost passes through the zip
  entry compression — and `gzip`), because clients expect plain bytes.

## Layout

```
src/sideload.sidl     API definition (service Sideload: SideloadFactory)
src/service.rs        service implementation (permission checks + backends)
src/backend.rs        apps UDS and vhost clients
daemon/               child daemon crate, spawned by api-daemon
client/               esbuild bundling of the generated JS client
build.sh              build child daemon + JS client into <repo>/files
```

## Build

The service depends on the api-daemon crates, so `build.sh` materializes a
pinned api-daemon checkout under `services/.cache/api-daemon` and builds inside
it. The revision is pinned to the one matching the device firmware era
(`05fadcb809`, KaiOS 3.1): its generated JS client uses the session API shipped
in `/system/kaios/http_root` (`track`/`track_events`, not `registerService`).

```sh
ANDROID_NDK=$HOME/Android/Sdk/ndk/r21e services/Sideload/build.sh
```

Artifacts (committed, so the image build needs no Rust toolchain):

- `files/sideload-daemon` — child daemon
- `files/sideload-service.js.gz` — JS client bundle

## Deployment

`patches/12-sideload.sh` installs the child daemon and the JS client into
`/system/kaios`, registers the `sideload` permission in Gecko's
`PermissionsTable` (granted to packaged and core applications that declare it),
and installs the patched `files/api-daemon.sh`, which copies both into
`/data/local/service/api-daemon/` on every boot.

## Client usage

```html
<script src="http://127.0.0.1/api/v1/shared/core.js"></script>
<script src="http://127.0.0.1/api/v1/shared/session.js"></script>
<script src="http://127.0.0.1/api/v1/sideload/service.js"></script>
<script>
navigator.b2g.externalapi.getToken().then((token) => {
  const session = new lib_session.Session();
  session.open('websocket', '127.0.0.1', token, {
    onsessionconnected() {
      lib_sideload.Sideload.get(session).then(async (sideload) => {
        const apps = await sideload.list();
        await sideload.install('/storage/sdcard/app.zip');
      });
    },
  }, true);
});
</script>
```

The application manifest must declare the permission:

```json
"b2g_features": { "permissions": { "sideload": {} } }
```
