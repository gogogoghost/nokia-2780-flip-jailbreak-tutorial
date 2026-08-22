#!/bin/sh

# Mark all bundled non-core apps removable so they can be uninstalled
# from the launcher. Apps without the removable field are core apps
# and stay non-removable.

json_update "$SYSTEM_ROOT/system/b2g/webapps/webapps.json" \
    'map(if .removable == false then .removable = true else . end)'

set_file_metadata root:root 0644 "$SYSTEM_ROOT/system/b2g/webapps/webapps.json"
