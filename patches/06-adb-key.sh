#!/bin/sh

# Restore the ADB key to /data/misc/adb/adb_keys at boot so the
# computer can connect with the repo's adbkey.

mkdir -p "$SYSTEM_ROOT/system/adb"
cp "$FILES_DIR/init.copy_adb_key.rc" "$SYSTEM_ROOT/system/etc/init/"
cp "$FILES_DIR/copy_adb_key" "$SYSTEM_ROOT/system/bin/"
cp "$PROJECT_DIR/adbkey.pub" "$SYSTEM_ROOT/system/adb/adb_keys"

set_file_metadata root:root 0644 "$SYSTEM_ROOT/system/etc/init/init.copy_adb_key.rc"
set_file_metadata root:2000 0755 "$SYSTEM_ROOT/system/bin/copy_adb_key"
set_file_metadata root:root 0644 "$SYSTEM_ROOT/system/adb/adb_keys"
