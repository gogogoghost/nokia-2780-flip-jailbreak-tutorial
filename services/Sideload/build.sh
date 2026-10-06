#!/bin/sh

# Build the Sideload remote service.
#
# Produces (into $OUTPUT_DIR, default <repo>/files):
#   sideload-daemon          child daemon for /system/kaios/remote/Sideload/daemon
#   sideload-service.js.gz   JS client for /system/kaios/http_root/api/v1/sideload/
#
# The service depends on the api-daemon crates, its vendored third party crates
# and its workspace patches, so it is built inside a pinned api-daemon checkout
# materialized under services/.cache/api-daemon.
#
# Environment:
#   ANDROID_NDK         Android NDK (default ~/Android/Sdk/ndk/r21e)
#   RUST_TOOLCHAIN      Rust toolchain (default 1.62.0)
#   API_DAEMON_REPO     api-daemon repository (default upstream)
#   API_DAEMON_COMMIT   pinned commit to build against
#   OUTPUT_DIR          artifact directory (default <repo>/files)
#   SKIP_CLIENT         set to 1 to skip the JS client bundle

set -e

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
service_dir=$repo_dir/services/Sideload
cache_dir=$repo_dir/services/.cache
api_daemon_dir=$cache_dir/api-daemon
output_dir=${OUTPUT_DIR:-$repo_dir/files}

android_ndk=${ANDROID_NDK:-$HOME/Android/Sdk/ndk/r21e}
rust_toolchain=${RUST_TOOLCHAIN:-1.62.0}
api_daemon_repo=${API_DAEMON_REPO:-https://github.com/kaiostech/api-daemon}
# Pinned to the api-daemon revision matching the device firmware era
# (KaiOS 3.1 / daemon 3.1.0): its generated JS client uses the session API
# shipped in /system/kaios/http_root (track/track_events, not registerService).
api_daemon_commit=${API_DAEMON_COMMIT:-05fadcb8093e1873ea7d1c0013711ede69d0740b}

ndk_toolchain=$android_ndk/toolchains/llvm/prebuilt/linux-x86_64
ndk_linker=$ndk_toolchain/bin/armv7a-linux-androideabi29-clang
ndk_strip=$ndk_toolchain/bin/llvm-strip

if [ ! -x "$ndk_linker" ]; then
    echo "Android NDK not found at $android_ndk (set ANDROID_NDK)" >&2
    exit 1
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
rm -rf "$api_daemon_dir/services/Sideload" "$api_daemon_dir/child-sideload-daemon"
mkdir -p "$api_daemon_dir/services/Sideload"
cp -r "$service_dir/Cargo.toml" "$service_dir/build.rs" "$service_dir/src" "$api_daemon_dir/services/Sideload/"
cp -r "$service_dir/client" "$api_daemon_dir/services/Sideload/"
mkdir -p "$api_daemon_dir/child-sideload-daemon"
cp -r "$service_dir/daemon/Cargo.toml" "$service_dir/daemon/src" "$api_daemon_dir/child-sideload-daemon/"

python3 - "$api_daemon_dir/Cargo.toml" <<'PY'
import sys

path = sys.argv[1]
text = open(path).read()
members = ['"services/Sideload"', '"child-sideload-daemon"']
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

echo "Building sideload-daemon ..."
(
    cd "$api_daemon_dir"
    BUILD_WITH_NDK_DIR=$android_ndk \
    CC_armv7_linux_androideabi=$ndk_linker \
    AR_armv7_linux_androideabi=$ndk_toolchain/bin/llvm-ar \
        cargo "+$rust_toolchain" build --release -p sideload-daemon
)

mkdir -p "$output_dir"
cp "$api_daemon_dir/target/armv7-linux-androideabi/release/sideload-daemon" "$output_dir/sideload-daemon"
"$ndk_strip" "$output_dir/sideload-daemon"
echo "  -> $output_dir/sideload-daemon"

echo "Done."
