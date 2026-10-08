//! Everything that actually touches the device: starting and stopping the
//! `kcap` helper, and reading back what it leaves behind.
//!
//! kcap needs root (it ptraces the HWC HAL to read the display buffers), but a
//! child daemon runs as uid 10000 + id. So the recording is started through
//! `/system/xbin/su`, which the jailbreak installs and which grants root
//! without a prompt even to a process with no terminal.
//!
//! Talking to kcap needs no protocol of its own: the helper already publishes
//! everything this service needs next to its output file.
//!
//!   /data/local/tmp/screencapture.mp4            the recording
//!   /data/local/tmp/screencapture.mp4.progress   "elapsed=<s> frames=<n> fps=<r>"
//!   /data/local/tmp/screencapture.mp4.stop       created to ask for a clean stop
//!   /data/local/tmp/screencapture.log            kcap's own output, for errors
//!
//! `/data/local/tmp` is mode 1777, so the daemon can create, read and delete
//! those files directly and only the recorder itself needs su.

use log::{info, warn};
use std::fs;
use std::process::{Child, Command, Stdio};
use std::thread;
use std::time::Duration;

/// The on-device recorder, installed by the image build.
pub const KCAP: &str = "/system/xbin/kcap";
/// The su helper, installed by images/system/02-su.py.
pub const SU: &str = "/system/xbin/su";

pub const OUT_DIR: &str = "/data/local/tmp";
pub const MP4: &str = "/data/local/tmp/screencapture.mp4";
pub const PROGRESS: &str = "/data/local/tmp/screencapture.mp4.progress";
pub const STOP: &str = "/data/local/tmp/screencapture.mp4.stop";
pub const LOG: &str = "/data/local/tmp/screencapture.log";

/// The panel refresh rate; kcap records in real time at this rate.
pub const FPS: u32 = 29;

/// How long kcap may take to either fail or get going before record() reports
/// success. It exits within milliseconds when it cannot attach to the HAL.
const STARTUP_GRACE_MS: u64 = 400;
/// How long stop() waits for the MP4 to be finalised (moov atom written).
const STOP_TIMEOUT: Duration = Duration::from_secs(60);

/// The process-wide recording state, shared by every client session.
pub struct Recorder {
    child: Option<Child>,
    /// Last elapsed value seen, so elapsed() still answers after the helper has
    /// removed its progress file on the way out.
    last_elapsed: f64,
}

impl Recorder {
    pub fn new() -> Self {
        Recorder {
            child: None,
            last_elapsed: 0.0,
        }
    }

    /// Drop the child handle once the process is gone.
    fn reap(&mut self) {
        if let Some(child) = self.child.as_mut() {
            match child.try_wait() {
                Ok(Some(status)) => {
                    info!("recorder exited with {}", status);
                    self.child = None;
                }
                Ok(None) => {}
                Err(err) => {
                    warn!("cannot poll the recorder: {}", err);
                    self.child = None;
                }
            }
        }
    }

    pub fn is_recording(&mut self) -> bool {
        self.reap();
        self.child.is_some()
    }

    pub fn start(&mut self, bitrate: i64) -> Result<(), String> {
        self.reap();
        if self.child.is_some() {
            info!("already recording, leaving it alone");
            return Ok(());
        }
        if bitrate < 1000 || bitrate > 100_000_000 {
            return Err(format!(
                "bitrate {} is out of range (use 1000..100000000 bit/s)",
                bitrate
            ));
        }

        // A stale stop file would end the new recording immediately; kcap drops
        // it too, but removing it here keeps the intent obvious.
        let _ = fs::remove_file(STOP);
        let _ = fs::remove_file(PROGRESS);
        let _ = fs::remove_file(MP4);

        let command = format!(
            "{} rec --mp4 --bitrate={} --progress=1 {} 0 {}",
            KCAP, bitrate, MP4, FPS
        );
        info!("starting the recorder: {} -c '{}'", SU, command);

        let log = fs::File::create(LOG).map_err(|err| format!("cannot open {}: {}", LOG, err))?;
        let log_copy = log
            .try_clone()
            .map_err(|err| format!("cannot duplicate {}: {}", LOG, err))?;

        let child = Command::new(SU)
            .arg("-c")
            .arg(&command)
            .stdin(Stdio::null())
            .stdout(Stdio::from(log))
            .stderr(Stdio::from(log_copy))
            .spawn()
            .map_err(|err| format!("cannot run {}: {}", SU, err))?;

        self.child = Some(child);
        self.last_elapsed = 0.0;
        thread::sleep(Duration::from_millis(STARTUP_GRACE_MS));

        if !self.is_recording() {
            return Err(format!("the recorder did not start: {}", failure_detail()));
        }
        Ok(())
    }

    pub fn stop(&mut self) -> Result<(), String> {
        self.reap();
        if self.child.is_none() {
            return Err("there is no recording to stop".into());
        }

        if let Some(elapsed) = read_elapsed() {
            self.last_elapsed = elapsed;
        }

        // A stop request is a request, not a kill: kcap flushes the encoder and
        // finishes the MP4 before it exits, which is what we wait for.
        fs::write(STOP, b"stop\n").map_err(|err| format!("cannot create {}: {}", STOP, err))?;

        let mut child = self.child.take().expect("checked above");
        let deadline = std::time::Instant::now() + STOP_TIMEOUT;
        loop {
            match child.try_wait() {
                Ok(Some(status)) => {
                    info!("recorder stopped with {}", status);
                    break;
                }
                Ok(None) => {
                    if std::time::Instant::now() >= deadline {
                        warn!("recorder did not stop in time, leaving it running");
                        self.child = Some(child);
                        return Err("the recorder did not stop in time".into());
                    }
                    thread::sleep(Duration::from_millis(100));
                }
                Err(err) => {
                    warn!("cannot poll the recorder: {}", err);
                    break;
                }
            }
        }
        let _ = child.wait();
        let _ = fs::remove_file(STOP);
        Ok(())
    }

    /// Whole seconds, for the reason given in the sidl: this firmware's shared
    /// client has no f64 decoder.
    pub fn elapsed(&mut self) -> i64 {
        self.reap();
        if let Some(elapsed) = read_elapsed() {
            self.last_elapsed = elapsed;
        }
        self.last_elapsed as i64
    }

    pub fn take_blob(&mut self) -> Result<Vec<u8>, String> {
        self.reap();
        if self.child.is_some() {
            return Err("a recording is still running, stop it first".into());
        }

        let data = fs::read(MP4).map_err(|err| {
            format!("there is no recording to return: {}", err)
        })?;

        // The blob has been handed over, so the file and its helpers go.
        let _ = fs::remove_file(MP4);
        let _ = fs::remove_file(PROGRESS);
        let _ = fs::remove_file(STOP);
        self.last_elapsed = 0.0;
        Ok(data)
    }
}

/// Reads `elapsed=` from kcap's progress file, if it is there.
fn read_elapsed() -> Option<f64> {
    let text = fs::read_to_string(PROGRESS).ok()?;
    text.split_whitespace()
        .find_map(|field| field.strip_prefix("elapsed="))
        .and_then(|value| value.parse::<f64>().ok())
}

/// The last meaningful line kcap logged, to explain why it refused to start.
fn failure_detail() -> String {
    let mut lines: Vec<String> = fs::read_to_string(LOG)
        .unwrap_or_default()
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty())
        // progress and summary lines mean it did start, so they are not the reason
        .filter(|line| !line.contains("s elapsed,") && !line.contains("frames written"))
        .map(str::to_owned)
        .collect();
    match lines.pop() {
        Some(line) => line,
        None => "no output from the recorder".into(),
    }
}
