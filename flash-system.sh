#!/bin/sh

set -e

if [ $# -ne 1 ]; then
    echo "Usage: $0 <system-image-path>" >&2
    exit 1
fi

system_image=$1

if [ ! -f "$system_image" ]; then
    echo "System image not found: $system_image" >&2
    exit 1
fi

fastboot oem sudo
fastboot flash system "$system_image"
fastboot format userdata
fastboot format cache
