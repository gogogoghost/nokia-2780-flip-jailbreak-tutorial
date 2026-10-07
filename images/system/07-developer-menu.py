#!/usr/bin/env python3

# Keep the hidden Developer menu and the Remote Debugger option visible.

from patchlib import image_path, json_merge, set_metadata

settings = image_path("/system/b2g/defaults/settings.json")

json_merge(settings, {
    "developer.menu.enabled": True,
    "devtools.remote.wifi.visible": True,
})
set_metadata(settings, 0o644, "root:root")
