#!/bin/sh

# Overwrite init.usb.configfs.rc with the patched version that keeps
# the "USB storage and ADB" switch functional.

cp "$FILES_DIR/init.usb.configfs.rc" "$SYSTEM_ROOT/"
set_file_metadata root:root 0644 "$SYSTEM_ROOT/init.usb.configfs.rc"
