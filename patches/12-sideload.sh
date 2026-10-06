#!/bin/sh

# Install the Sideload remote service:
#   - child daemon in /system/kaios/remote/Sideload/daemon
#   - JS client in /system/kaios/http_root/api/v1/sideload/service.js.gz
#   - `sideload` permission in Gecko's PermissionsTable
#   - patched api-daemon.sh that syncs both into /data on every boot

mkdir -p "$SYSTEM_ROOT/system/kaios/remote/Sideload"
cp "$PROJECT_DIR/files/sideload-daemon" "$SYSTEM_ROOT/system/kaios/remote/Sideload/daemon"
set_file_metadata root:root 0755 "$SYSTEM_ROOT/system/kaios/remote/Sideload/daemon"

mkdir -p "$SYSTEM_ROOT/system/kaios/http_root/api/v1/sideload"
cp "$PROJECT_DIR/files/sideload-service.js.gz" "$SYSTEM_ROOT/system/kaios/http_root/api/v1/sideload/service.js.gz"
set_file_metadata root:root 0644 "$SYSTEM_ROOT/system/kaios/http_root/api/v1/sideload/service.js.gz"

cp "$PROJECT_DIR/files/api-daemon.sh" "$SYSTEM_ROOT/system/bin/api-daemon.sh"
set_file_metadata root:2000 0755 "$SYSTEM_ROOT/system/bin/api-daemon.sh"

# Register the `sideload` permission. Applications declare it in their manifest
# (b2g_features.permissions); PermissionsInstaller grants it for packaged
# (signed) and core applications.
python3 - "$SYSTEM_ROOT/system/b2g/omni.ja" <<'PY'
import os
import sys
import zipfile

omni_path = sys.argv[1]
target = "modules/PermissionsTable.jsm"
needle = "this.PermissionsTable={"
entry = '"sideload":{pwa:DENY_ACTION,signed:ALLOW_ACTION,core:ALLOW_ACTION},'
tmp_path = omni_path + ".tmp"

with zipfile.ZipFile(omni_path, "r") as src, zipfile.ZipFile(tmp_path, "w") as dst:
    replaced = False

    for info in src.infolist():
        data = src.read(info.filename)
        if info.filename == target:
            text = data.decode("utf-8")
            if '"sideload"' not in text:
                if needle not in text:
                    os.unlink(tmp_path)
                    raise SystemExit("PermissionsTable not found in %s" % target)
                text = text.replace(needle, needle + entry, 1)
            data = text.encode("utf-8")
            replaced = True
        dst.writestr(info, data)

if not replaced:
    os.unlink(tmp_path)
    raise SystemExit("%s not found in omni.ja" % target)

os.replace(tmp_path, omni_path)
PY

set_file_metadata root:root 0644 "$SYSTEM_ROOT/system/b2g/omni.ja"
