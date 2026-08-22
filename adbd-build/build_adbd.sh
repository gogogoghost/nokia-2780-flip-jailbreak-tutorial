#!/bin/bash
# Build the patched adbd for Nokia 2780 (KaiOS, Android 10 / API 29).
#
# Reproduces files/adbd-new.bin from AOSP sources. The binary:
#   - always keeps root (should_drop_privileges() returns false)
#   - trusts every adb key (adbd_auth_verify() returns true, auth_required=false)
#   - links libadbd logic statically; dynamically links system libs already
#     present on the device (/system/lib)
#
# Requirements (run from this directory):
#   - Android NDK r21e: set NDK_HOME or pass --ndk <path>
#     download: https://dl.google.com/android/repository/android-ndk-r21e-linux-x86_64.zip
#   - device system partition image (for lib*.so extraction):
#     set SYSTEM_IMG=/path/to/system.img or emmc image; skips if unavailable
#   - ~6 GB disk for AOSP clones (shallow clones)
#
# Usage:
#   ./compile_adbd.sh [--ndkdir /path/to/android-ndk-r21e] [--system-img /path/system.img]
#
# Output: ../../files/adbd-new.bin  (repo files/ directory)
set -euo pipefail

cd "$(dirname "$0")"

NDK="${NDK_HOME:-${ANDROID_NDK_HOME:-}}"
SYSTEM_IMG="${SYSTEM_IMG:-}"
WORK="${WORK:-$(pwd)/work}"

# --- Parse args ---
while [ $# -gt 0 ]; do
    case "$1" in
        --ndkdir) NDK="$2"; shift 2;;
        --system-img) SYSTEM_IMG="$2"; shift 2;;
        *) echo "Unknown arg: $1" >&2; exit 1;;
    esac
done

if [ -z "$NDK" ] || [ ! -x "$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/armv7a-linux-androideabi29-clang++" ]; then
    echo "ERROR: NDK r21e not found. Set --ndkdir or NDK_HOME." >&2
    exit 1
fi

CXX="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/armv7a-linux-androideabi29-clang++"
CXX_STL="$NDK/sources/cxx-stl/llvm-libc++/libs/armeabi-v7a"
mkdir -p "$WORK" out

echo "==> Fetching AOSP system/core (android-10.0.0_r9)..."
SRC="$WORK/platform_system_core"
if [ ! -d "$SRC/.git" ]; then
    git clone --depth 1 --branch android-10.0.0_r9 \
        https://github.com/aosp-mirror/platform_system_core.git "$SRC"
fi

echo "==> Fetching dependency headers..."
fetch_headers() {  # repo path, output dir
    local repo="$1" out="$2"
    if [ ! -d "$WORK/deps/$out" ] || [ ! -e "$WORK/deps/$out/.fetched" ]; then
        curl -fsSL "https://android.googlesource.com/platform/$repo/+archive/refs/tags/android-10.0.0_r9.tar.gz" \
            -o "$WORK/deps-tmp-$out.tar.gz"
        rm -rf "$WORK/deps/$out"
        mkdir -p "$WORK/deps/$out"
        tar -xzf "$WORK/deps-tmp-$out.tar.gz" -C "$WORK/deps/$out"
        touch "$WORK/deps/$out/.fetched"
    fi
}
mkdir -p "$WORK/deps"
fetch_headers external/boringssl boringssl
fetch_headers external/minijail minijail
fetch_headers external/libcap libcap
fetch_headers external/selinux selinux

echo "==> Applying source patches..."
(cd "$SRC" && git checkout -- adb/daemon 2>/dev/null || true)
(cd "$SRC" && git apply "$OLDPWD/patches/0001-source-patches.patch" || true)

echo "==> Extracting device libs..."
LIBS="$WORK/device-libs"
mkdir -p "$LIBS"
if [ -n "$SYSTEM_IMG" ] && [ -f "$SYSTEM_IMG" ]; then
    for lib in liblog libcutils libcrypto libcrypto_utils libselinux libminijail libcap libz libc++; do
        debugfs -R "dump /system/lib/$lib.so $LIBS/$lib.so" "$SYSTEM_IMG" 2>/dev/null || true
    done
else
    echo "    WARNING: no system image; assuming device libs at $LIBS"
fi

echo "==> Compiling adbd..."
CPPFLAGS="-O2 -fPIC -DADB_HOST=0 -DALLOW_ADBD_ROOT=1 -D_GNU_SOURCE -std=c++2a \
  -I$SRC/adb -I$SRC/adb/daemon/include -I$SRC/adb/daemon \
  -I$SRC/base/include -I$SRC/libcutils/include -I$SRC/liblog/include \
  -I$SRC/libcrypto_utils/include -I$SRC/libasyncio/include -I$SRC/libutils/include \
  -I$SRC/diagnose_usb/include -I$WORK/deps/selinux/libselinux/include \
  -I$WORK/deps/minijail -I$WORK/deps/libcap/libcap/include \
  -I$WORK/deps/boringssl/src/include -Istubs \
  -include stubs/platform_tools_version.h"

LDFLAGS="-L$LIBS -llog -lcutils -lcrypto -lcrypto_utils -lselinux -lminijail -lcap -lm -ldl -lz \
  -L$CXX_STL -Wl,--start-group -lc++_static -lc++abi -lunwind -Wl,--end-group"

SRCS="$SRC/adb/adb.cpp $SRC/adb/adb_io.cpp $SRC/adb/adb_listeners.cpp $SRC/adb/adb_trace.cpp \
  $SRC/adb/adb_unique_fd.cpp $SRC/adb/adb_utils.cpp $SRC/adb/fdevent.cpp $SRC/adb/services.cpp \
  $SRC/adb/sockets.cpp $SRC/adb/socket_spec.cpp $SRC/adb/sysdeps/errno.cpp \
  $SRC/adb/transport.cpp $SRC/adb/transport_fd.cpp $SRC/adb/transport_local.cpp \
  $SRC/adb/transport_usb.cpp $SRC/adb/sysdeps_unix.cpp $SRC/adb/sysdeps/posix/network.cpp \
  $SRC/adb/daemon/main.cpp $SRC/adb/daemon/auth.cpp $SRC/adb/daemon/jdwp_service.cpp \
  $SRC/adb/daemon/services.cpp $SRC/adb/daemon/usb.cpp $SRC/adb/daemon/usb_ffs.cpp \
  $SRC/adb/daemon/usb_legacy.cpp $SRC/adb/daemon/file_sync_service.cpp \
  $SRC/adb/daemon/shell_service.cpp $SRC/adb/shell_service_protocol.cpp \
  $SRC/adb/daemon/framebuffer_service.cpp $SRC/adb/daemon/reboot_service.cpp \
  $SRC/adb/daemon/remount_service.cpp $SRC/adb/daemon/restart_service.cpp \
  $SRC/base/chrono_utils.cpp $SRC/base/cmsg.cpp $SRC/base/file.cpp $SRC/base/logging.cpp \
  $SRC/base/mapped_file.cpp $SRC/base/parsenetaddress.cpp $SRC/base/properties.cpp \
  $SRC/base/quick_exit.cpp $SRC/base/stringprintf.cpp $SRC/base/strings.cpp \
  $SRC/base/threads.cpp $SRC/libasyncio/AsyncIO.cpp \
  stubs/transport_qemu_stub.cpp stubs/extra_stubs.cpp"

"$CXX" $CPPFLAGS -o out/adbd $SRCS $LDFLAGS \
    -Wl,--dynamic-linker=/system/bin/linker -Wl,-rpath-link,"$LIBS"

echo "==> Copying to files/adbd-new.bin"
cp out/adbd "$(cd .. && pwd)/files/adbd-new.bin"
file out/adbd
echo "Done."
