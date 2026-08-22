#!/bin/sh

# Replace /system/bin/init with a patched init binary that keeps
# adb and root shell available (recovery, root access, ADB).

cp "$DOWNLOAD_DIR/init" "$SYSTEM_ROOT/system/bin/init"
set_file_metadata root:2000 0755 "$SYSTEM_ROOT/system/bin/init"
