#!/usr/bin/env python3

# Overwrite init.usb.configfs.rc with the patched version that keeps
# the "USB storage and ADB" switch functional.

from patchlib import FILES, install_file

install_file(FILES / "init.usb.configfs.rc", "/init.usb.configfs.rc", 0o644, "root:root")
