/// Sideload child daemon.
///
/// Spawned by api-daemon when an application with the `sideload` permission calls
/// `get_service("Sideload", ...)`. It exposes a single remote service and speaks
/// the api-daemon child protocol over the inherited `IPC_FD`.
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

// Exposes the Sideload service as remoted in this process.
expose_remote_service!(sideload_service::service::SideloadImpl, sideload_service, SideloadImpl);

fn main() {
    init_logger(true);

    info!("Starting sideload-daemon");

    match session::Session::start() {
        Err(session::SessionError::MissingEnvVar) => {
            error!("No fd specified, stopping.");
        }
        Err(session::SessionError::BadFdValue(fd_s)) => {
            error!("{} can't be used as a file descriptor, stopping", fd_s);
        }
        _ => {}
    }

    info!("sideload-daemon exiting");
}
