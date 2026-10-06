#!/usr/bin/env python3

# Inject debugger_settings_bridge.js into the system app: add the script tag to
# index.html and the file itself into application.zip, so the USB Debugger /
# Remote Debugger switches take effect immediately.

from patchlib import FILES, image_path, set_metadata, zip_add, zip_edit

system_zip = image_path("/system/b2g/webapps/system/application.zip")

zip_add(system_zip, {
    "js/debugger_settings_bridge.js": FILES / "debugger_settings_bridge.js",
})
zip_edit(system_zip, "index.html", FILES / "debugger-bridge-script-tag.html",
         before='    <script defer="" src="js/bootstrap.js"></script>')
set_metadata(system_zip, 0o644, "root:root")
