#!/usr/bin/env python3

# Patch the settings app: add the Developer panel files and rename the USB
# storage toggle to "USB storage and ADB" in the en-US locale.

from patchlib import FILES, image_path, set_metadata, zip_add, zip_json

settings_zip = image_path("/system/b2g/webapps/settings/application.zip")

zip_add(settings_zip, {
    "elements/developer.html": FILES / "settings-developer.html",
    "js/panels/developer/panel.js": FILES / "settings-developer-panel.js",
})


def rename_usb_storage(locale):
    for entry in locale:
        if entry.get("$i") in ("enableUSBStorage1", "enable-USBStorage1-header"):
            entry["$v"] = "USB storage and ADB"
    return locale


zip_json(settings_zip, "locales-obj/en-US.json", rename_usb_storage)
set_metadata(settings_zip, 0o644, "root:root")
