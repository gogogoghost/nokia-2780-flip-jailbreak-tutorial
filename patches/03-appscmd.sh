#!/bin/sh

# Install appscmd and its init script for command-line app management.

cp "$DOWNLOAD_DIR/appscmd" "$SYSTEM_ROOT/system/xbin/"
cp "$FILES_DIR/init.appscmd.rc" "$SYSTEM_ROOT/system/etc/init/"
set_file_metadata root:2000 0755 "$SYSTEM_ROOT/system/xbin/appscmd"
set_file_metadata root:root 0644 "$SYSTEM_ROOT/system/etc/init/init.appscmd.rc"
