#!/bin/sh

# Make the Wi-Fi debugger use a fixed TCP port and a settings-driven flow:
# replace RemoteDebugger.js and SettingsPrefsSync.jsm in omni.ja and
# install the remote-debugger preference file.

patch_omni_file "$SYSTEM_ROOT/system/b2g/omni.ja" \
    "chrome/chrome/content/devtools/RemoteDebugger.js" \
    "$FILES_DIR/RemoteDebugger.js"

patch_omni_file "$SYSTEM_ROOT/system/b2g/omni.ja" \
    "modules/SettingsPrefsSync.jsm" \
    "$FILES_DIR/SettingsPrefsSync.jsm"

mkdir -p "$SYSTEM_ROOT/system/b2g/defaults/pref"
cp "$FILES_DIR/remote-debugger.pref.js" "$SYSTEM_ROOT/system/b2g/defaults/pref/remote-debugger.js"
set_file_metadata root:root 0644 "$SYSTEM_ROOT/system/b2g/defaults/pref/remote-debugger.js"
set_file_metadata root:root 0644 "$SYSTEM_ROOT/system/b2g/omni.ja"
