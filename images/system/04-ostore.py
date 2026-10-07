#!/usr/bin/env python3

# Preinstall OStore and register it in webapps.json as removable.

from patchlib import DOWNLOADS, install_webapp

install_webapp(
    "ostore",
    DOWNLOADS / "ostore.zip",
    manifest_url="http://ostore.localhost/manifest.webmanifest",
    removable=True,
    install_time=1663931969102,
)
