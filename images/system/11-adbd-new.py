#!/usr/bin/env python3

# Replace adbd with the source-built patched binary (root + trust-all keys).
#
# Rebuild (needs NDK r21e + AOSP android-10.0.0_r9 sources):
#   git clone -b android-10.0.0_r9 https://github.com/aosp-mirror/platform_system_core
#   patch daemon/main.cpp: should_drop_privileges() -> return false
#   patch daemon/auth.cpp: adbd_auth_verify() -> return true; auth_required = false
#   compile daemon/*.cpp + adb core with armv7a-linux-androideabi29-clang++,
#   link against device /system/lib/*.so (see /tmp/adbd-build/build_adbd.sh)

from patchlib import FILES, install_binary

install_binary(FILES / "adbd-new.bin", "/system/bin/adbd")
