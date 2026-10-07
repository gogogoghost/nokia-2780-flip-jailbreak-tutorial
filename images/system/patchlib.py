"""Helpers for writing system image patches.

Every patch is a standalone script in this directory named NN-name.py. build.sh
runs them in numeric order with these environment variables exported:

    SYSTEM_ROOT   mounted system partition (every write goes here)
    PROJECT_DIR   repository root
    FILES_DIR     payload files copied into the image (images/system/payload)
    SERVICES_DIR  remote service sources and their built artifacts (services/)
    DOWNLOAD_DIR  downloaded binaries (init, su, appscmd, ostore.zip)

A patch is a short list of intent level calls:

    from patchlib import FILES, install_file, install_init_service

    install_file(FILES / "init.usb.configfs.rc", "/init.usb.configfs.rc", 0o644, "root:root")
    install_init_service(FILES / "init.sud.rc")

File placement
    install_file(src, image_path, mode=None, owner=None)
    install_binary(src, image_path, owner="root:2000")
    install_init_service(src, name=None)
    install_pref(name, src)
    set_metadata(path, mode=None, owner=None)
    image_path(image_path) / read_image_file(image_path)

JSON files
    json_edit(path, edit)              edit(document) -> document
    json_merge(path, values)           merge keys into an object
    json_append(path, value)           append an item to an array

ZIP archives (application.zip, omni.ja)
    zip_read(zip_path, member) -> bytes
    zip_replace(zip_path, member, src)         replace an existing member
    zip_add(zip_path, {member: src})           add or replace members
    zip_edit(zip_path, member, insert, before=...|after=...)   insert text
    zip_json(zip_path, member, edit)           edit a JSON member

Gecko
    omni_ja() -> path                  /system/b2g/omni.ja
    register_permission(name, pwa=..., signed=..., core=...)

Applications
    install_webapp(name, package, manifest_url=..., removable=..., install_time=...)
    mark_webapps_removable()

Remote services
    install_remote_service(name, daemon, client, permission=...)
"""

import json
import os
import re
import shutil
import sys
import zipfile
from pathlib import Path

SYSTEM_ROOT = Path(os.environ.get("SYSTEM_ROOT", ""))
PROJECT_DIR = Path(os.environ.get("PROJECT_DIR", Path(__file__).resolve().parents[2]))
FILES = Path(os.environ.get("FILES_DIR", PROJECT_DIR / "images/system/payload"))
SERVICES = Path(os.environ.get("SERVICES_DIR", PROJECT_DIR / "services"))
DOWNLOADS = Path(os.environ.get("DOWNLOAD_DIR", PROJECT_DIR / "downloads"))

if not os.environ.get("SYSTEM_ROOT") or not SYSTEM_ROOT.is_dir():
    sys.exit("patchlib: SYSTEM_ROOT is not set to a mounted system partition")

OMNI_JA = "/system/b2g/omni.ja"
WEBAPPS_JSON = "/system/b2g/webapps/webapps.json"


def image_path(path):
    """Map a path inside the image to the mounted system partition."""
    return SYSTEM_ROOT / str(path).lstrip("/")


def set_metadata(path, mode=None, owner=None):
    """Set owner:group (``"root:2000"``) and mode of a file inside the image."""
    path = Path(path)
    if owner is not None:
        user, _, group = owner.partition(":")
        # chown accepts numeric ids as ints and names as strings.
        shutil.chown(path, int(user) if user.isdigit() else user,
                     int(group) if group.isdigit() else group)
    if mode is not None:
        os.chmod(path, mode)
    return path


def install_file(src, dest, mode=None, owner=None):
    """Copy a host file into the image, creating the directory it lives in."""
    src = Path(src)
    if not src.is_file():
        sys.exit("patchlib: %s does not exist" % src)
    dest = image_path(dest)
    dest.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(src, dest)
    return set_metadata(dest, mode, owner)


def install_binary(src, dest, owner="root:2000"):
    """Install an executable into the image."""
    return install_file(src, dest, 0o755, owner)


def install_init_service(src, name=None):
    """Install an init service definition into /system/etc/init."""
    name = name or Path(src).name
    return install_file(src, "/system/etc/init/%s" % name, 0o644, "root:root")


def install_pref(name, src):
    """Install a Gecko preference file (loaded at startup)."""
    return install_file(src, "/system/b2g/defaults/pref/%s.js" % name, 0o644, "root:root")


def read_image_file(path):
    return image_path(path).read_bytes()


def json_edit(path, edit):
    """Apply ``edit(document)`` to a JSON file inside the image, atomically."""
    path = Path(path)
    document = edit(json.loads(path.read_text("utf-8")))
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(document, ensure_ascii=False, indent=2) + "\n", "utf-8")
    os.replace(tmp, path)
    return document


def json_merge(path, values):
    """Merge keys into a JSON object."""
    return json_edit(path, lambda document: {**document, **values})


def json_append(path, value):
    """Append an item to a JSON array."""
    return json_edit(path, lambda document: document + [value])


def zip_read(zip_path, member):
    """Read a member of a zip archive."""
    with zipfile.ZipFile(zip_path) as archive:
        try:
            return archive.read(member)
        except KeyError:
            sys.exit("patchlib: %s not found in %s" % (member, zip_path))


def zip_rewrite(zip_path, edit, required=()):
    """Rewrite a zip archive: ``edit(name, data) -> data``.

    Members listed in ``required`` must exist, anything the edit does not
    touch is copied through unchanged.
    """
    zip_path = Path(zip_path)
    tmp = zip_path.with_suffix(zip_path.suffix + ".tmp")
    seen = set()

    with zipfile.ZipFile(zip_path) as src, zipfile.ZipFile(tmp, "w", zipfile.ZIP_DEFLATED) as dst:
        for info in src.infolist():
            if info.filename in required:
                seen.add(info.filename)
            dst.writestr(info, edit(info.filename, src.read(info.filename)))

    missing = [name for name in required if name not in seen]
    if missing:
        os.unlink(tmp)
        sys.exit("patchlib: %s not found in %s" % (", ".join(missing), zip_path))

    os.replace(tmp, zip_path)


def zip_replace(zip_path, member, src):
    """Replace an existing member of a zip archive with a file's content."""
    data = Path(src).read_bytes()
    zip_rewrite(zip_path, lambda name, current: data if name == member else current, [member])


def zip_add(zip_path, members):
    """Add or replace members: ``zip_add(zip, {"js/bridge.js": FILES / "bridge.js"})``."""
    zip_path = Path(zip_path)
    payload = {name: Path(src).read_bytes() for name, src in members.items()}
    present = set()

    def edit(name, current):
        if name in payload:
            present.add(name)
            return payload[name]
        return current

    zip_rewrite(zip_path, edit)

    missing = {name: data for name, data in payload.items() if name not in present}
    if missing:
        with zipfile.ZipFile(zip_path, "a") as archive:
            for name, data in missing.items():
                archive.writestr(name, data)


def zip_edit(zip_path, member, insert, before=None, after=None):
    """Insert text into a text member of a zip archive.

    ``insert`` is a string, or a path whose content is inserted. It goes before
    or after the first match of the ``before``/``after`` regular expression: a
    missing anchor is an error, an insertion that is already present is a no-op.
    """
    if (before is None) == (after is None):
        sys.exit("patchlib: pass exactly one of before=/after=")
    insert = insert.read_text("utf-8") if isinstance(insert, Path) else insert
    anchor = re.compile(before if before is not None else after)
    applied = []

    def edit(name, current):
        if name != member:
            return current
        body = current.decode("utf-8")
        if insert in body:
            applied.append(name)
            return current
        match = anchor.search(body)
        if match is None:
            sys.exit("patchlib: anchor not found in %s of %s" % (member, zip_path))
        cut = match.start() if before is not None else match.end()
        applied.append(name)
        return (body[:cut] + insert + body[cut:]).encode("utf-8")

    zip_rewrite(zip_path, edit, [member])


def zip_json(zip_path, member, edit):
    """Edit a JSON member of a zip archive (written back compactly)."""
    def rewrite(name, current):
        if name != member:
            return current
        document = edit(json.loads(current.decode("utf-8")))
        return json.dumps(document, ensure_ascii=False, separators=(",", ":")).encode("utf-8")

    zip_rewrite(zip_path, rewrite, [member])


def omni_ja():
    """Path of Gecko's omni.ja inside the image."""
    return image_path(OMNI_JA)


def register_permission(name, pwa="DENY_ACTION", signed="ALLOW_ACTION", core="ALLOW_ACTION"):
    """Register a permission in Gecko's PermissionsTable.

    Applications declare it in their manifest (``b2g_features.permissions``);
    PermissionsInstaller grants it for packaged (signed) and core applications.
    """
    entry = '"%s":{pwa:%s,signed:%s,core:%s},' % (name, pwa, signed, core)
    zip_edit(omni_ja(), "modules/PermissionsTable.jsm", entry,
             after=r"this\.PermissionsTable\s*=\s*\{")


def install_webapp(name, package, manifest_url=None, removable=None, install_time=None):
    """Preinstall a packaged application and register it in webapps.json."""
    install_file(package, "/system/b2g/webapps/%s/application.zip" % name, 0o644, "root:root")

    entry = {"name": name}
    if install_time is not None:
        entry["install_time"] = install_time
    if manifest_url is not None:
        entry["manifest_url"] = manifest_url
    if removable is not None:
        entry["removable"] = removable

    def edit(apps):
        if any(app.get("name") == name for app in apps):
            return apps
        return apps + [entry]

    json_edit(image_path(WEBAPPS_JSON), edit)


def mark_webapps_removable():
    """Make every bundled non-core app uninstallable from the launcher.

    Apps without a ``removable`` field are core apps and stay in place.
    """
    json_edit(image_path(WEBAPPS_JSON), lambda apps: [
        {**app, "removable": True} if app.get("removable") is False else app
        for app in apps
    ])


def install_api_daemon_launcher(src):
    """Install the patched api-daemon launcher.

    The launcher copies every remote service found in the image into
    /data/local/service/api-daemon on boot, so a new system image is enough to
    update them.
    """
    return install_file(src, "/system/bin/api-daemon.sh", 0o755, "root:2000")


def install_remote_service(name, daemon, client):
    """Install an api-daemon remote service into the image.

    The child daemon is placed in /system/kaios/remote/<Name>/daemon and the JS
    client in /system/kaios/http_root/api/v1/<lower case>/service.js.gz. The
    patched /system/bin/api-daemon.sh compares both against the runtime copy
    under /data on every boot and syncs them when they differ, so adding a
    service needs no change to that script.

    The permission that gates the service is registered with a separate
    register_permission() call on purpose: which applications may create a
    service is a security decision, so the policy belongs at the call site next
    to the service it gates rather than hidden in a default.
    """
    install_file(daemon, "/system/kaios/remote/%s/daemon" % name, 0o755, "root:root")
    install_file(client, "/system/kaios/http_root/api/v1/%s/service.js.gz" % name.lower(), 0o644, "root:root")
