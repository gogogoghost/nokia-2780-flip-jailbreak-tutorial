#!/bin/sh

# Refresh the LOCAL_SOURCE_DIR mirror used by local act runs.
#
# build.sh downloads the eMMC dump, init, su, appscmd and ostore.zip from
# release URLs. test.sh mounts a local mirror of those files into the container
# so repeated local runs do not download hundreds of megabytes every time.
#
# The mirror goes stale whenever one of those releases is updated - a new OStore
# version for example - and a stale mirror silently makes local builds differ
# from CI. This script reads the URLs straight out of build.sh (the single
# source of truth, so version bumps do not have to be repeated here) and updates
# every file that changed, leaving the others alone.
#
# LOCAL_SOURCE_DIR is taken from the environment first, then from .env.local.

set -e

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
build_script="$repo_dir/build.sh"

mirror=${LOCAL_SOURCE_DIR:-}
if [ -z "$mirror" ] && [ -f "$repo_dir/.env.local" ]; then
    . "$repo_dir/.env.local"
    mirror=${LOCAL_SOURCE_DIR:-}
fi

if [ -z "$mirror" ]; then
    echo "LOCAL_SOURCE_DIR is not set (see .env.example and .env.local)" >&2
    exit 1
fi

mkdir -p "$mirror"
echo "Updating $mirror"

sed -n 's/^download_file \([^ ]*\) \([^ ]*\)$/\1 \2/p' "$build_script" |
while read -r name url; do
    target="$mirror/$name"
    if [ -f "$target" ]; then
        before=$(sha256sum "$target" | cut -d' ' -f1)
    else
        before=none
    fi

    # --timestamping only fetches what the server reports as newer; the plain
    # download is a fallback for servers that do not send Last-Modified.
    wget --quiet --timestamping --directory-prefix "$mirror" "$url" ||
        wget --quiet "$url" -O "$target"

    if [ -f "$target" ]; then
        after=$(sha256sum "$target" | cut -d' ' -f1)
    else
        after=none
    fi

    if [ "$before" = "$after" ]; then
        echo "  $name: up to date"
    elif [ "$before" = "none" ]; then
        echo "  $name: downloaded"
    else
        echo "  $name: updated"
    fi
done
