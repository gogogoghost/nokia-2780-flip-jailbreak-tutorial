/// screencapture child daemon.
///
/// Spawned by api-daemon when an application with the `screencapture` permission
/// calls `get_service("screencapture", ...)`. It exposes a single remote service
/// and speaks the api-daemon child protocol over the inherited `IPC_FD`.
///
/// It is deliberately thin: the recording is a `kcap` process it starts through
/// su and then just watches (see src/backend.rs).
use common::expose_remote_service;
use log::{error, info};
#[cfg(not(target_os = "android"))]
use std::io::Write;

#[cfg(target_os = "android")]
fn init_logger(verbose: bool) {
    use android_logger::Filter;
    use log::Level;

    let level = if verbose {
        Filter::default().with_min_level(Level::Debug)
    } else {
        Filter::default().with_min_level(Level::Info)
    };
    android_logger::init_once(level);
}

#[cfg(not(target_os = "android"))]
fn init_logger(_verbose: bool) {
    env_logger::Builder::from_default_env()
        .format(|buf, record| {
            let ts = buf.timestamp();
            match record.module_path() {
                Some(module_path) => {
                    writeln!(buf, "{} {:<5} {} {}", ts, record.level(), module_path, record.args())
                }
                None => writeln!(buf, "{} {:<5} {}", ts, record.level(), record.args()),
            }
        })
        .try_init()
        .expect("Failed to initialize logger.");
}

// Exposes the screencapture service as remoted in this process.
expose_remote_service!(
    screencapture_service::service::ScreencaptureImpl,
    screencapture_service,
    ScreencaptureImpl
);

fn main() {
    init_logger(true);

    info!("Starting screencapture-daemon");

    match session::Session::start() {
        Err(session::SessionError::MissingEnvVar) => {
            error!("No fd specified, stopping.");
        }
        Err(session::SessionError::BadFdValue(fd_s)) => {
            error!("{} can't be used as a file descriptor, stopping", fd_s);
        }
        _ => {}
    }

    info!("screencapture-daemon exiting");
}
