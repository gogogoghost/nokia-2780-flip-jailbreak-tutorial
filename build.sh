#!/bin/sh

# Build the patched images.
#
# This script prepares the environment (downloads, loop device, mount), runs
# every patch in images/system/ in numeric order against the mounted system
# partition, dumps it to output/system-patched.img, and builds output/dtbo.img
# from images/dtbo/. Each patch modifies exactly one feature;
# images/system/patchlib.py has the shared helpers.
#
# Exported environment available to every patch script:
#   SYSTEM_ROOT    mounted system partition (all patches write here)
#   PROJECT_DIR    repository root
#   FILES_DIR      repository files/ directory
#   DOWNLOAD_DIR   directory with init, su, appscmd, ostore.zip

set -e

download_base_url=${DOWNLOAD_BASE_URL:-}
compress_output=${COMPRESS_OUTPUT:-}
local_source_dir=${LOCAL_SOURCE_DIR:-}

root_dir="root"
downloads_dir="downloads"
output_dir="output"

system_mounted=0
image_loop_device=
system_partition_device=
system_partition_device_created=0

if [ -z "$compress_output" ]; then
    compress_output=1
fi

if [ -n "$download_base_url" ]; then
    download_base_url=${download_base_url%/}
fi

# Paths exported for the patch scripts.
export PROJECT_DIR="$(pwd)"
export FILES_DIR="$PROJECT_DIR/images/system/payload"
export SERVICES_DIR="$PROJECT_DIR/services"
export DOWNLOAD_DIR="$PROJECT_DIR/$downloads_dir"
export SYSTEM_ROOT="$PROJECT_DIR/$root_dir"

# Patch scripts run from the repository root.
cd "$PROJECT_DIR"

cleanup() {
    if [ "$system_mounted" = "1" ]; then
        umount "$root_dir" 2>/dev/null || true
        system_mounted=0
    fi

    if [ -n "$image_loop_device" ]; then
        if [ "$system_partition_device_created" = "1" ]; then
            rm -f "$system_partition_device"
            system_partition_device_created=0
        fi

        losetup --detach "$image_loop_device" 2>/dev/null || true
        image_loop_device=
        system_partition_device=
    fi
}

trap cleanup EXIT

mkdir -p "$output_dir" "$downloads_dir"

if [ "$(id -u)" -ne 0 ]; then
    echo "This build must run as root to mount the system partition." >&2
    exit 1
fi

echo "Download build files..."
LOCAL_SOURCE_DIR="$local_source_dir" DOWNLOAD_BASE_URL="$download_base_url" \
    sh "$PROJECT_DIR/tools/download-resources.sh" "$downloads_dir"

echo "Decompress emmc image..."
xz -dkf "$downloads_dir/emmc.img.xz"

mkdir -p "$root_dir"

if ! command -v losetup >/dev/null 2>&1 || ! command -v mount >/dev/null 2>&1; then
    echo "losetup or mount not found" >&2
    exit 1
fi

echo "Attach eMMC image and scan its partitions..."
if [ -n "$local_source_dir" ] && [ -f "$local_source_dir/emmc.img" ]; then
    image_loop_device=$(losetup --find --show --partscan "$local_source_dir/emmc.img")
else
    image_loop_device=$(losetup --find --show --partscan "$downloads_dir/emmc.img")
fi
system_partition_device="${image_loop_device}p16"

if [ ! -e "$system_partition_device" ]; then
    system_partition_name=${system_partition_device##*/}
    system_partition_numbers=$(cat "/sys/class/block/$system_partition_name/dev" 2>/dev/null || true)
    system_partition_major=${system_partition_numbers%%:*}
    system_partition_minor=${system_partition_numbers##*:}

    case "$system_partition_major:$system_partition_minor" in
        *[!0-9:]*|*:|:*)
            echo "Failed to read device numbers for system partition 16" >&2
            exit 1
            ;;
    esac

    mknod "$system_partition_device" b "$system_partition_major" "$system_partition_minor"
    system_partition_device_created=1
fi

if [ ! -b "$system_partition_device" ]; then
    echo "System partition 16 was not found on $image_loop_device" >&2
    exit 1
fi

echo "Mount system partition..."
mount "$system_partition_device" "$root_dir"
system_mounted=1

echo "Apply patches..."
for patch_script in "$PROJECT_DIR"/images/system/[0-9]*.py; do
    if [ -f "$patch_script" ]; then
        echo "  $(basename "$patch_script")"
        # Patches import the shared helpers from images/system/patchlib.py,
        # which Python finds next to the script being run.
        python3 "$patch_script"
    fi
done

sync

echo "Umount system..."
umount "$root_dir"
system_mounted=0

echo "Dump system partition..."
dd if="$system_partition_device" of="$output_dir/system-patched.img" bs=4M status=progress

echo "Build dtbo image..."
if [ -n "$local_source_dir" ] && [ -f "$local_source_dir/emmc.img" ]; then
    emmc_image="$local_source_dir/emmc.img"
else
    emmc_image="$downloads_dir/emmc.img"
fi
python3 "$PROJECT_DIR/images/dtbo/debounce.py" "$emmc_image" "$output_dir/dtbo.img"

cleanup

echo "Check system image..."
e2fsck -fy "$output_dir/system-patched.img" || status=$?

if [ "${status:-0}" -gt 1 ]; then
    exit "$status"
fi

if [ "$compress_output" = "1" ]; then
    echo "Compress image..."
    xz -T0 "$output_dir/system-patched.img"
fi

echo "Done. Image: $output_dir/system-patched.img"
