#!/bin/sh

# Shared helpers for patches. Source this from each patch script:
#   . "$(dirname "$0")/lib.sh"
#
# Requires the environment prepared by build.sh:
#   SYSTEM_ROOT   - mounted system partition
#   PROJECT_DIR   - repository root
#   FILES_DIR     - repository files/ directory
#   DOWNLOAD_DIR  - downloaded binaries (init, su, appscmd, ostore.zip)

set -e

if [ -z "$SYSTEM_ROOT" ] || [ ! -d "$SYSTEM_ROOT" ]; then
    echo "lib.sh: SYSTEM_ROOT is not set to a mounted system partition" >&2
    exit 1
fi

: "${PROJECT_DIR:?PROJECT_DIR is not set}"
FILES_DIR="${FILES_DIR:-$PROJECT_DIR/files}"
DOWNLOAD_DIR="${DOWNLOAD_DIR:-$PROJECT_DIR/downloads}"

# Set owner:group and mode of a file inside the system partition.
set_file_metadata() {
    owner_group=$1
    mode=$2
    path=$3

    chown "$owner_group" "$path"
    chmod "$mode" "$path"
}

# Atomically update a JSON file with a jq filter.
json_update() {
    file=$1
    filter=$2

    tmp=$(mktemp)
    trap 'rm -f "$tmp"' EXIT
    jq "$filter" "$file" > "$tmp"
    mv "$tmp" "$file"
    trap - EXIT
}

# Replace an entry inside omni.ja with the given file.
patch_omni_file() {
    archive_path=$1
    target_name=$2
    replacement_path=$3

    python3 - "$archive_path" "$target_name" "$replacement_path" <<'PY'
import os
import sys
import zipfile

omni_path, target_name, replacement_path = sys.argv[1:4]
tmp_path = omni_path + ".tmp"

with zipfile.ZipFile(omni_path, "r") as src, zipfile.ZipFile(tmp_path, "w") as dst:
    replacement = open(replacement_path, "rb").read()
    replaced = False

    for info in src.infolist():
        data = replacement if info.filename == target_name else src.read(info.filename)
        if info.filename == target_name:
            replaced = True
        dst.writestr(info, data)

if not replaced:
    os.unlink(tmp_path)
    raise SystemExit(f"{target_name} not found in omni.ja")

os.replace(tmp_path, omni_path)
PY
}
