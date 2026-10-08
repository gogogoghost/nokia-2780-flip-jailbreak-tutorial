#!/bin/sh

# Build the screencapture remote service.
#
# Produces (into $OUTPUT_DIR, default services/Screencapture/dist):
#   daemon           child daemon for /system/kaios/remote/screencapture/daemon
#   kcap             the on-device recorder for /system/xbin/kcap
#   service.js.gz    JS client for /system/kaios/http_root/api/v1/screencapture/
#
# The artifacts are committed so the image build needs no Rust or NDK
# toolchain; the patch that installs them reads them from this directory.
#
# The service depends on the api-daemon crates, its vendored third party crates
# and its workspace patches, so it is built inside a pinned api-daemon checkout
# materialized under services/.cache/api-daemon. kcap only needs the NDK.
#
# Environment:
#   ANDROID_NDK         Android NDK (default ~/Android/Sdk/ndk/r21e)
#   RUST_TOOLCHAIN      Rust toolchain (default 1.62.0)
#   API_DAEMON_REPO     api-daemon repository (default upstream)
#   API_DAEMON_COMMIT   pinned commit to build against
#   OUTPUT_DIR          artifact directory (default services/Screencapture/dist)
#   SKIP_CLIENT         set to 1 to skip the JS client bundle
#   SKIP_KCAP           set to 1 to skip the on-device recorder

set -e

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
service_dir=$repo_dir/services/Screencapture
cache_dir=$repo_dir/services/.cache
api_daemon_dir=$cache_dir/api-daemon
output_dir=${OUTPUT_DIR:-$repo_dir/services/Screencapture/dist}

android_ndk=${ANDROID_NDK:-$HOME/Android/Sdk/ndk/r21e}
rust_toolchain=${RUST_TOOLCHAIN:-1.62.0}
api_daemon_repo=${API_DAEMON_REPO:-https://github.com/kaiostech/api-daemon}
# Same pinned revision as the other services: the api-daemon of the device
# firmware era (KaiOS 3.1 / daemon 3.1.0).
api_daemon_commit=${API_DAEMON_COMMIT:-05fadcb8093e1873ea7d1c0013711ede69d0740b}

ndk_toolchain=$android_ndk/toolchains/llvm/prebuilt/linux-x86_64
ndk_linker=$ndk_toolchain/bin/armv7a-linux-androideabi29-clang
ndk_strip=$ndk_toolchain/bin/llvm-strip

if [ ! -x "$ndk_linker" ]; then
    echo "Android NDK not found at $android_ndk (set ANDROID_NDK)" >&2
    exit 1
fi

# `common` declares #[link(name = "selinux")], and is also built for the host
# for the build scripts. On a distribution without a host libselinux that link
# would fail, so provide a link-only stub: build scripts only use the codegen
# helpers and never call security_getenforce(). This keeps the build root-free.
host_libs=$cache_dir/host-libs
if [ ! -f "$host_libs/libselinux.so" ]; then
    mkdir -p "$host_libs"
    printf '/* link-only stub: build scripts never call this */\nint security_getenforce(void) { return -1; }\n' \
        > "$host_libs/selinux_stub.c"
    ${CC:-cc} -shared -fPIC -o "$host_libs/libselinux.so" "$host_libs/selinux_stub.c"
fi
LIBRARY_PATH="$host_libs${LIBRARY_PATH:+:$LIBRARY_PATH}"
LD_LIBRARY_PATH="$host_libs${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export LIBRARY_PATH LD_LIBRARY_PATH

mkdir -p "$output_dir"

if [ "${SKIP_KCAP:-0}" != "1" ]; then
    echo "Building kcap ..."
    # kcap links libmediandk, a system shared library that cannot be linked
    # statically, so it is dynamic -- and built as C++ because the NDK's media
    # headers do not compile as C.
    "$ndk_toolchain/bin/armv7a-linux-androideabi29-clang++" -O2 -Wall -x c++ \
        -D_FILE_OFFSET_BITS=64 -o "$output_dir/kcap" "$service_dir/kcap.c" \
        -lmediandk -llog -pthread
    "$ndk_strip" "$output_dir/kcap"
    echo "  -> $output_dir/kcap"
fi

echo "Fetching api-daemon $api_daemon_commit ..."
mkdir -p "$cache_dir"
if [ ! -d "$api_daemon_dir/.git" ]; then
    git clone "$api_daemon_repo" "$api_daemon_dir"
fi
git -C "$api_daemon_dir" fetch --depth 1 origin "$api_daemon_commit"
git -C "$api_daemon_dir" checkout --detach --force "$api_daemon_commit"
# Drop files from previous builds (service copies, generated clients) but keep
# the cargo target directory so rebuilds stay fast.
git -C "$api_daemon_dir" clean -fdq -e target

echo "Laying out the service inside the api-daemon tree ..."
rm -rf "$api_daemon_dir/services/Screencapture" "$api_daemon_dir/child-Screencapture-daemon"
mkdir -p "$api_daemon_dir/services/Screencapture"
cp -r "$service_dir/Cargo.toml" "$service_dir/build.rs" "$service_dir/src" "$api_daemon_dir/services/Screencapture/"
cp -r "$service_dir/client" "$api_daemon_dir/services/Screencapture/"
mkdir -p "$api_daemon_dir/child-Screencapture-daemon"
cp -r "$service_dir/daemon/Cargo.toml" "$service_dir/daemon/src" "$api_daemon_dir/child-Screencapture-daemon/"

python3 - "$api_daemon_dir/Cargo.toml" <<'PY'
import sys

path = sys.argv[1]
text = open(path).read()
members = ['"services/Screencapture"', '"child-Screencapture-daemon"']
missing = [member for member in members if member not in text]
if missing:
    text = text.replace('members = [', 'members = [\n  ' + ',\n  '.join(missing) + ',', 1)
    open(path, 'w').write(text)
    print('added workspace members:', ', '.join(missing))
PY

echo "Configuring the cross compilation target ..."
if ! grep -q 'armv7-linux-androideabi' "$api_daemon_dir/.cargo/config"; then
    cat >> "$api_daemon_dir/.cargo/config" <<EOF

[build]
target = "armv7-linux-androideabi"

[target.armv7-linux-androideabi]
linker = "$ndk_linker"
rustflags = ["-C", "opt-level=z"]
EOF
fi

echo "Building screencapture-daemon ..."
(
    cd "$api_daemon_dir"
    BUILD_WITH_NDK_DIR=$android_ndk \
    CC_armv7_linux_androideabi=$ndk_linker \
    AR_armv7_linux_androideabi=$ndk_toolchain/bin/llvm-ar \
        cargo "+$rust_toolchain" build --release -p screencapture-daemon
)

cp "$api_daemon_dir/target/armv7-linux-androideabi/release/screencapture-daemon" "$output_dir/daemon"
"$ndk_strip" "$output_dir/daemon"
echo "  -> $output_dir/daemon"

if [ "${SKIP_CLIENT:-0}" != "1" ]; then
    echo "Building the JS client ..."
    # The bundle input is generated/screencapture_service.js, which the child
    # daemon's build.rs writes next to the sources inside the api-daemon
    # checkout, so the client is bundled there rather than in the repository
    # copy.
    client_dir="$api_daemon_dir/services/Screencapture/client"
    if [ ! -d "$client_dir/node_modules" ]; then
        echo "  client/node_modules is missing: run 'npm install' in $service_dir/client" >&2
        exit 1
    fi
    (cd "$client_dir" && node build.mjs)
    # -n keeps the gzip header free of a timestamp, so the artifact only
    # changes when the bundle does.
    gzip -9n -c "$client_dir/dist/service.js" > "$output_dir/service.js.gz"
    echo "  -> $output_dir/service.js.gz"
fi

echo "Done."
