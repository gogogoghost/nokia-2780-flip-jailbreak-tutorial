#!/usr/bin/env python3

# Install appscmd as a command line tool for app management over ADB.
#
# The appscmd *daemon* (an unauthenticated HTTP API on 127.0.0.1:5431) is no
# longer started: Sideload (12-sideload.py) provides the same app management to
# applications, gated by the `sideload` permission.

from patchlib import DOWNLOADS, install_binary

install_binary(DOWNLOADS / "appscmd", "/system/xbin/appscmd")
