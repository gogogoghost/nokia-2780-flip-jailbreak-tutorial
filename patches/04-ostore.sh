#!/bin/sh

# Preinstall OStore and register it in webapps.json as removable.

mkdir -p "$SYSTEM_ROOT/system/b2g/webapps/ostore"
cp "$DOWNLOAD_DIR/ostore.zip" "$SYSTEM_ROOT/system/b2g/webapps/ostore/application.zip"
set_file_metadata root:root 0644 "$SYSTEM_ROOT/system/b2g/webapps/ostore/application.zip"

json_update "$SYSTEM_ROOT/system/b2g/webapps/webapps.json" \
    '. += [{"install_time": 1663931969102, "manifest_url": "http://ostore.localhost/manifest.webmanifest", "removable": true, "name": "ostore"}]'
