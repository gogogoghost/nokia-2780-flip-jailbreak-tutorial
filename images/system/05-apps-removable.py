#!/usr/bin/env python3

# Mark all bundled non-core apps removable so they can be uninstalled from the
# launcher. Apps without the removable field are core apps and stay in place.

from patchlib import mark_webapps_removable

mark_webapps_removable()
