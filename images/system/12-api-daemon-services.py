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
# install_remote_service() places the two files and register_permission() grants
# the permission, on purpose as two calls: which applications may create a
# service is a security decision, so it stays visible next to the service it
# gates. The patched launcher installed first syncs every service found in the
# image into the api-daemon runtime copy under /data on boot, so adding a service
# needs no change to that script.

from patchlib import (FILES, SERVICES, install_api_daemon_launcher,
                      install_remote_service, register_permission)

# The launcher that starts api-daemon and refreshes the services under /data.
install_api_daemon_launcher(FILES / "api-daemon.sh")

# --- remote services ---------------------------------------------------------
# One block per service: the two files, then the permission that gates it. The
# artifacts are built by services/<Name>/build.sh into services/<Name>/dist/ and
# committed, so the image build needs no Rust toolchain.

install_remote_service(
    "Sideload",
    daemon=SERVICES / "Sideload/dist/daemon",
    client=SERVICES / "Sideload/dist/service.js.gz",
)
# Packaged (signed) and core applications that declare `sideload` in their
# manifest may create the service; web apps may not. OStore declares it.
register_permission("sideload")
