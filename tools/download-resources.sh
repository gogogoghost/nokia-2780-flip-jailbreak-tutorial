#!/bin/sh

# Download the files the image build needs into a target directory.
#
# One script for both users:
#   - the build itself:      download-resources.sh downloads
#   - the local act cache:   download-resources.sh "$LOCAL_SOURCE_DIR" --download
#
# Sources are tried in order: the local mirror ($LOCAL_SOURCE_DIR, skipped when
# it is the target), an alternative base ($DOWNLOAD_BASE_URL) and finally the
# release URL below. --download ignores the local mirror and always fetches,
# which is what refreshing the cache needs. Files the server reports as
# unchanged are not fetched again, so refreshing does not pull the 400 MB eMMC
# dump every time.

set -e

target=${1:-}
mode=${2:-}

if [ -z "$target" ]; then
    echo "usage: download-resources.sh <target-dir> [--download]" >&2
    exit 1
fi

mkdir -p "$target"

download() {
    name=$1
    url=$2

    if [ "$mode" != "--download" ] &&
       [ -n "${LOCAL_SOURCE_DIR:-}" ] &&
       [ "$LOCAL_SOURCE_DIR" != "$target" ] &&
       [ -f "$LOCAL_SOURCE_DIR/$name" ]; then
        cp "$LOCAL_SOURCE_DIR/$name" "$target/$name"
        echo "  $name: from local mirror"
        return
    fi

    if [ -n "${DOWNLOAD_BASE_URL:-}" ]; then
        url="${DOWNLOAD_BASE_URL%/}/$name"
    fi

    before=$(sha256sum "$target/$name" 2>/dev/null | cut -d' ' -f1)
    wget --quiet --timestamping --directory-prefix "$target" "$url" ||
        wget --quiet "$url" -O "$target/$name"
    after=$(sha256sum "$target/$name" 2>/dev/null | cut -d' ' -f1)

    if [ -z "$after" ]; then
        echo "  $name: download failed" >&2
        exit 1
    elif [ "$before" = "$after" ]; then
        echo "  $name: up to date"
    elif [ -z "$before" ]; then
        echo "  $name: downloaded"
    else
        echo "  $name: updated"
    fi
}

echo "Downloading build files into $target"

download emmc.img.xz https://github.com/gogogoghost/nokia-2780-flip-jailbreak-tutorial/releases/download/emmc/emmc.img.xz
download init https://github.com/gogogoghost/nokia-2780-flip-jailbreak-tutorial/releases/download/patched-files/init
download su https://github.com/gogogoghost/nokia-2780-flip-jailbreak-tutorial/releases/download/su/su
download appscmd https://github.com/gogogoghost/appscmd/releases/download/0.1.0/appscmd
download ostore.zip https://github.com/gogogoghost/ostore-solid/releases/download/1.2.1/ostore.zip
