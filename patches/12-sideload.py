#!/usr/bin/env python3

# Install the Sideload remote service: the child daemon, its JS client and the
# `sideload` permission. install_remote_service() also takes care of the boot
# time sync, which api-daemon.sh does for every service shipped in the image.

from patchlib import FILES, install_api_daemon_launcher, install_remote_service

install_api_daemon_launcher(FILES / "api-daemon.sh")
install_remote_service(
    "Sideload",
    daemon=FILES / "sideload-daemon",
    client=FILES / "sideload-service.js.gz",
)
