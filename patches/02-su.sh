#!/bin/sh

# Install su and its init service so adb shell can get root.

cp "$DOWNLOAD_DIR/su" "$SYSTEM_ROOT/system/xbin/"
cp "$FILES_DIR/init.sud.rc" "$SYSTEM_ROOT/system/etc/init/"
set_file_metadata root:2000 0755 "$SYSTEM_ROOT/system/xbin/su"
set_file_metadata root:root 0644 "$SYSTEM_ROOT/system/etc/init/init.sud.rc"
