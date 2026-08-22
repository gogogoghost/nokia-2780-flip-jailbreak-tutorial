#!/bin/sh

# Patch the settings app: add the Developer panel files and rename
# the USB storage toggle to "USB storage and ADB" in the en-US locale.

python3 - "$SYSTEM_ROOT/system/b2g/webapps/settings/application.zip" "$FILES_DIR/settings-developer.html" "$FILES_DIR/settings-developer-panel.js" <<'PY'
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

set_file_metadata root:root 0644 "$SYSTEM_ROOT/system/b2g/webapps/settings/application.zip"
