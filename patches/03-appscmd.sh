#!/bin/sh

# Install appscmd as a command line tool for app management over ADB.
#
# The appscmd *daemon* (an unauthenticated HTTP API on 127.0.0.1:5431) is no
# longer started: Sideload (patches/12-sideload.sh) provides the same app
# management to applications, gated by the `sideload` permission.

cp "$DOWNLOAD_DIR/appscmd" "$SYSTEM_ROOT/system/xbin/"
set_file_metadata root:2000 0755 "$SYSTEM_ROOT/system/xbin/appscmd"
