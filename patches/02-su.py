#!/usr/bin/env python3

# Install su and its init service so adb shell can get root.

from patchlib import DOWNLOADS, FILES, install_binary, install_init_service

install_binary(DOWNLOADS / "su", "/system/xbin/su")
install_init_service(FILES / "init.sud.rc")
