#!/usr/bin/env python3

# Restore the ADB key to /data/misc/adb/adb_keys at boot so the
# computer can connect with the repo's adbkey.

from patchlib import FILES, PROJECT_DIR, install_binary, install_file, install_init_service

install_init_service(FILES / "init.copy_adb_key.rc")
install_binary(FILES / "copy_adb_key", "/system/bin/copy_adb_key")
install_file(PROJECT_DIR / "adbkey.pub", "/system/adb/adb_keys", 0o644, "root:root")
