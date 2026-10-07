#!/usr/bin/env python3

# Make the Wi-Fi debugger use a fixed TCP port and a settings-driven flow:
# replace RemoteDebugger.js and SettingsPrefsSync.jsm in omni.ja and install
# the remote-debugger preference file.

from patchlib import FILES, install_pref, omni_ja, set_metadata, zip_replace

zip_replace(omni_ja(), "chrome/chrome/content/devtools/RemoteDebugger.js",
            FILES / "RemoteDebugger.js")
zip_replace(omni_ja(), "modules/SettingsPrefsSync.jsm",
            FILES / "SettingsPrefsSync.jsm")
set_metadata(omni_ja(), 0o644, "root:root")

install_pref("remote-debugger", FILES / "remote-debugger.pref.js")
