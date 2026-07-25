#!/bin/sh

set -e

download_base_url=${DOWNLOAD_BASE_URL:-}
compress_output=${COMPRESS_OUTPUT:-}

root_dir="root"
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

download_file() {
    file_name=$1
    default_url=$2

    if [ -n "$download_base_url" ]; then
        wget "$download_base_url/$file_name" -O "$file_name"
    else
        wget "$default_url" -O "$file_name"
    fi
}

set_file_metadata() {
    owner_group=$1
    mode=$2
    path=$3

    chown "$owner_group" "$path"
    chmod "$mode" "$path"
}

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

patch_system_index() {
    python3 - "$root_dir/system/b2g/webapps/system/index.html" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()
needle = '    <script defer="" src="js/bootstrap.js"></script>\n'
insert = '    <script defer="" src="js/debugger_settings_bridge.js"></script>\n' + needle

if 'js/debugger_settings_bridge.js' not in text:
    text = text.replace(needle, insert)

path.write_text(text)
PY
}

patch_system_app_zip() {
    python3 - "$root_dir/system/b2g/webapps/system/application.zip" "$(pwd)/files/debugger_settings_bridge.js" <<'PY'
import os
import sys
import zipfile

zip_path, bridge_path = sys.argv[1:3]
tmp_path = zip_path + ".tmp"
bridge_arc = "js/debugger_settings_bridge.js"
index_arc = "index.html"

with zipfile.ZipFile(zip_path, "r") as src, zipfile.ZipFile(tmp_path, "w") as dst:
    bridge_data = open(bridge_path, "rb").read()
    replaced_index = False

    for info in src.infolist():
        data = src.read(info.filename)
        if info.filename == index_arc:
            text = data.decode("utf-8")
            needle = '    <script defer="" src="js/bootstrap.js"></script>\n'
            insert = '    <script defer="" src="js/debugger_settings_bridge.js"></script>\n' + needle
            if 'js/debugger_settings_bridge.js' not in text:
                text = text.replace(needle, insert)
            data = text.encode("utf-8")
            replaced_index = True
        dst.writestr(info, data)

    if not replaced_index:
        os.unlink(tmp_path)
        raise SystemExit("index.html not found in system application.zip")

    dst.writestr(bridge_arc, bridge_data)

os.replace(tmp_path, zip_path)
PY
}

patch_settings_app_zip() {
    python3 - "$root_dir/system/b2g/webapps/settings/application.zip" "$(pwd)/files/settings-developer.html" "$(pwd)/files/settings-developer-panel.js" <<'PY'
import os
import json
import sys
import zipfile

zip_path, developer_html_path, developer_panel_path = sys.argv[1:4]
tmp_path = zip_path + ".tmp"
targets = {
    "elements/developer.html": open(developer_html_path, "rb").read(),
    "js/panels/developer/panel.js": open(developer_panel_path, "rb").read(),
}
replaced = {key: False for key in targets}
locale_name = "locales-obj/en-US.json"
locale_replaced = False

with zipfile.ZipFile(zip_path, "r") as src, zipfile.ZipFile(tmp_path, "w") as dst:
    for info in src.infolist():
        data = src.read(info.filename)
        if info.filename in targets:
            data = targets[info.filename]
            replaced[info.filename] = True
        elif info.filename == locale_name:
            locale = json.loads(data.decode("utf-8"))
            for entry in locale:
                if entry.get("$i") == "enableUSBStorage1":
                    entry["$v"] = "USB storage and ADB"
                elif entry.get("$i") == "enable-USBStorage1-header":
                    entry["$v"] = "USB storage and ADB"
            data = json.dumps(locale, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
            locale_replaced = True
        dst.writestr(info, data)

missing = [name for name, ok in replaced.items() if not ok]
if missing or not locale_replaced:
    os.unlink(tmp_path)
    problems = missing + ([locale_name] if not locale_replaced else [])
    raise SystemExit("Missing settings app entries: " + ", ".join(problems))

os.replace(tmp_path, zip_path)
PY
}

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

output="output"
mkdir -p $output

if [ "$(id -u)" -ne 0 ]; then
    echo "This build must run as root to mount the system partition." >&2
    exit 1
fi

echo "Download emmc image..."
download_file emmc.img.xz https://github.com/gogogoghost/nokia-2780-flip-jailbreak-tutorial/releases/download/emmc/emmc.img.xz

echo "Download init..."
download_file init https://github.com/gogogoghost/nokia-2780-flip-jailbreak-tutorial/releases/download/patched-files/init

echo "Download su..."
download_file su https://github.com/gogogoghost/nokia-2780-flip-jailbreak-tutorial/releases/download/su/su

echo "Download appscmd..."
download_file appscmd https://github.com/gogogoghost/appscmd/releases/download/0.1.0/appscmd

echo "Download ostore..."
download_file ostore.zip https://github.com/gogogoghost/ostore-solid/releases/download/1.1.0/ostore.zip

echo "Decompress emmc image..."
xz -dk emmc.img.xz

mkdir -p "$root_dir"

if ! command -v losetup >/dev/null 2>&1 || ! command -v mount >/dev/null 2>&1; then
    echo "losetup or mount not found" >&2
    exit 1
fi

echo "Attach eMMC image and scan its partitions..."
image_loop_device=$(losetup --find --show --partscan "emmc.img")
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

echo "Copy files..."

# copy init
cp init "$root_dir/system/bin/init"

# overwrite init.usb.configfs.rc
cp files/init.usb.configfs.rc "$root_dir/"

# copy su
cp su "$root_dir/system/xbin/"
cp files/init.sud.rc "$root_dir/system/etc/init/"

# copy appscmd
cp appscmd "$root_dir/system/xbin/"
cp files/init.appscmd.rc "$root_dir/system/etc/init/"

# install ostore
mkdir -p "$root_dir/system/b2g/webapps/ostore"
cp ostore.zip "$root_dir/system/b2g/webapps/ostore/application.zip"
jq '. += [{"install_time": 1663931969102, "manifest_url": "http://ostore.localhost/manifest.webmanifest","removable": true,"name": "ostore"}]' "$root_dir/system/b2g/webapps/webapps.json" > temp.json && mv temp.json "$root_dir/system/b2g/webapps/webapps.json"

# check adb key when startup
mkdir -p "$root_dir/system/adb"
cp files/init.copy_adb_key.rc "$root_dir/system/etc/init/"
cp files/copy_adb_key "$root_dir/system/bin/"
cp adbkey.pub "$root_dir/system/adb/adb_keys"

# keep Developer menu and Remote Debugger visible
jq '. + {
  "developer.menu.enabled": true,
  "devtools.remote.wifi.visible": true
}' "$root_dir/system/b2g/defaults/settings.json" > temp.json && mv temp.json "$root_dir/system/b2g/defaults/settings.json"

# make Wi-Fi debugger use a fixed TCP port and settings-driven flow
patch_omni_file "$root_dir/system/b2g/omni.ja" "chrome/chrome/content/devtools/RemoteDebugger.js" "$(pwd)/files/RemoteDebugger.js"
patch_omni_file "$root_dir/system/b2g/omni.ja" "modules/SettingsPrefsSync.jsm" "$(pwd)/files/SettingsPrefsSync.jsm"
cp files/remote-debugger.pref.js "$root_dir/system/b2g/defaults/pref/remote-debugger.js"
patch_system_app_zip
patch_settings_app_zip

# keep ownership and modes aligned with the stock system image
set_file_metadata root:2000 0755 "$root_dir/system/xbin/su"
set_file_metadata root:2000 0755 "$root_dir/system/xbin/appscmd"
set_file_metadata root:2000 0755 "$root_dir/system/bin/copy_adb_key"
set_file_metadata root:root 0644 "$root_dir/system/etc/init/init.sud.rc"
set_file_metadata root:root 0644 "$root_dir/system/etc/init/init.appscmd.rc"
set_file_metadata root:root 0644 "$root_dir/system/etc/init/init.copy_adb_key.rc"
set_file_metadata root:root 0644 "$root_dir/system/adb/adb_keys"
set_file_metadata root:root 0644 "$root_dir/system/b2g/webapps/webapps.json"
set_file_metadata root:root 0644 "$root_dir/system/b2g/defaults/settings.json"
set_file_metadata root:root 0644 "$root_dir/system/b2g/defaults/pref/remote-debugger.js"
set_file_metadata root:root 0644 "$root_dir/system/b2g/webapps/system/application.zip"
set_file_metadata root:root 0644 "$root_dir/system/b2g/webapps/settings/application.zip"
set_file_metadata root:root 0644 "$root_dir/system/b2g/omni.ja"

sync

echo "Umount system..."
umount "$root_dir"
system_mounted=0

echo "Dump system partition..."
dd if="$system_partition_device" of="$output/system-patched.img" bs=4M status=progress

cleanup

echo "Check system image..."
e2fsck -fy "$output/system-patched.img" || status=$?

if [ "${status:-0}" -gt 1 ]; then
    exit "$status"
fi

if [ "$compress_output" = "1" ]; then
    echo "Compress image..."
    xz -T0 $output/system-patched.img
else
    echo "Skip compression..."
fi
