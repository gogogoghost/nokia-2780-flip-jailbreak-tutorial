#!/usr/bin/env python3

# Replace /system/bin/init with a patched init binary that keeps
# adb and root shell available (recovery, root access, ADB).

from patchlib import DOWNLOADS, install_binary

install_binary(DOWNLOADS / "init", "/system/bin/init")
