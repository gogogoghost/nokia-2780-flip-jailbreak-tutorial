#!/bin/sh

# Inject debugger_settings_bridge.js into the system app: add the script
# tag to index.html and the file itself into application.zip, so the
# USB Debugger / Remote Debugger switches take effect immediately.

python3 - "$SYSTEM_ROOT/system/b2g/webapps/system/application.zip" "$FILES_DIR/debugger_settings_bridge.js" <<'PY'
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

set_file_metadata root:root 0644 "$SYSTEM_ROOT/system/b2g/webapps/system/application.zip"
