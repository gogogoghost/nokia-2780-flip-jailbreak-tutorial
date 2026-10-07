#!/usr/bin/env python3

# Install the api-daemon remote services shipped in the image.
#
# A remote service needs three things:
#
#   /system/kaios/remote/<Name>/daemon                     the child daemon
#   /system/kaios/http_root/api/v1/<lower>/service.js.gz   its JS client
#   a PermissionsTable entry, so applications can be granted `<lower>` and are
#   then allowed to create the service
#
# install_remote_service() places all three. The patched launcher installed
# first syncs every service found in the image into the api-daemon runtime copy
# under /data on boot, so adding a service needs no change to that script.

from patchlib import FILES, SERVICES, install_api_daemon_launcher, install_remote_service

# The launcher that starts api-daemon and refreshes the services under /data.
install_api_daemon_launcher(FILES / "api-daemon.sh")

# --- remote services ---------------------------------------------------------
# One install_remote_service() call per service. The artifacts are built by
# services/<Name>/build.sh into services/<Name>/dist/ and committed, so the
# image build needs no Rust toolchain.

install_remote_service(
    "Sideload",
    daemon=SERVICES / "Sideload/dist/daemon",
    client=SERVICES / "Sideload/dist/service.js.gz",
)
