#!/bin/sh

# Refresh the api-daemon runtime payload from the system image.
#
# The daemon runs from /data/local/service/api-daemon, which the launcher
# (/system/bin/api-daemon.sh) rebuilds only when its `init` marker is missing
# (first boot, userdata wipe) or when the image ships a newer daemon version.
# Remote services are synced on every boot, the rest of the payload (daemon
# binary, http_root, config) is not: this forces a rebuild without rebooting,
# which is useful right after flashing an image.
#
# Removing the marker makes the launcher rebuild the payload - http_root,
# remote services, config and the daemon binary - on the next start, which is
# also the only moment it does that work. Nothing runs on a normal boot.

set -e

service_dir=/data/local/service/api-daemon

adb shell "su 0 sh -c '
    rm -f $service_dir/init
    stop api-daemon
    start api-daemon
'"

sleep 3
# The clients are served compressed, so the request has to accept gzip.
adb shell "curl -s -o /dev/null -w 'api-daemon HTTP %{http_code}\n' -H 'Accept-Encoding: gzip' http://127.0.0.1/api/v1/shared/core.js"
adb shell "ls -l $service_dir/remote"
