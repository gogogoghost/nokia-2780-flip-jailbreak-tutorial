#!/bin/sh

# Keep the hidden Developer menu and the Remote Debugger option visible.

json_update "$SYSTEM_ROOT/system/b2g/defaults/settings.json" \
    '. + {"developer.menu.enabled": true, "devtools.remote.wifi.visible": true}'
set_file_metadata root:root 0644 "$SYSTEM_ROOT/system/b2g/defaults/settings.json"
