# Contributor guide

This document explains how the build works, how to run it locally with
[act](https://github.com/nektos/act), and how to avoid re-downloading the
stock image on every local test.

## Repository layout

- `build.sh` — the build entry point. Prepares the environment: downloads
  the stock eMMC image and the patched binaries into `downloads/`, attaches
  the eMMC image with `losetup`, mounts its system partition at `root/`,
  runs every script in `patches/` in numeric order, then dumps the patched
  partition to `output/system-patched.img` and runs `e2fsck` on it.
- `patches/` — one script per feature, named `NN-name.py`. Each script
  modifies exactly one thing inside the mounted system partition, so
  individual patches can be reviewed, disabled (delete or rename the file),
  or extended without touching the others.
- `patches/patchlib.py` — shared helpers used by patch scripts: file
  placement, JSON edits, `application.zip`/`omni.ja` edits, application
  registration and remote service installation. Its docstring is the
  reference; patches import what they need.
- `files/` — files that are copied into the image as-is (init rc files,
  JavaScript bridges, developer panel sources).
- `files/adbd-new.bin` — a source-built patched `adbd` for the Nokia 2780.
  It is compiled from AOSP `android-10.0.0_r9` (`system/core/adb`) with two
  changes: `should_drop_privileges()` returns `false` (adbd always keeps
  root) and `adbd_auth_verify()` always returns true with `auth_required`
  disabled (any key accepted). It links libadbd's logic statically and the
  device's system libs (`liblog`, `libcrypto`, `libc++`, ...) dynamically;
  it does **not** use the device's `libadbd.so`/`libadbd_services.so`.
  The reproducible build lives in `adbd-build/` — see its `build_adbd.sh`
  header for prerequisites and usage.
- `test.sh` — runs the release workflow locally with act and unpacks the
  resulting image to the project parent directory.
- `.github/workflows/release.yml` — the GitHub Actions workflow that runs
  the same build on tag pushes and publishes the compressed image.

### Environment variables

`build.sh` exports the following variables before running each patch:

| Variable | Meaning |
|---|---|
| `SYSTEM_ROOT` | mounted system partition; all patches write here |
| `PROJECT_DIR` | repository root |
| `FILES_DIR` | repository `files/` directory |
| `DOWNLOAD_DIR` | `downloads/` directory (init, su, appscmd, ostore.zip) |

`patches/patchlib.py` reads them at import time and exposes them as the
`SYSTEM_ROOT`, `PROJECT_DIR`, `FILES` and `DOWNLOADS` paths. The helpers are
grouped by intent:

| Helper | Purpose |
|---|---|
| `install_file`, `install_binary`, `install_init_service`, `install_pref` | place a host file in the image with the right owner and mode |
| `set_metadata`, `image_path`, `read_image_file` | metadata and paths inside the image |
| `json_edit`, `json_merge`, `json_append` | edit JSON files in the image |
| `zip_read`, `zip_replace`, `zip_add`, `zip_edit`, `zip_json` | edit `application.zip` and `omni.ja` members |
| `register_permission` | register a permission in Gecko's `PermissionsTable` |
| `install_webapp`, `mark_webapps_removable` | preinstall applications in `webapps.json` |
| `install_remote_service`, `install_api_daemon_launcher` | install an api-daemon remote service (child daemon, JS client, permission) |

### Adding a patch

1. Create `patches/NN-name.py` with a number higher than the existing ones.
2. Import what you need, e.g. `from patchlib import FILES, install_file`.
3. Write only inside the image: `install_file()` and friends take image paths
   such as `/system/xbin/su` and create the directories they live in.
4. Set ownership and modes on every file you add — the stock image has
   strict metadata (e.g. binaries `root:2000 0755`, configs `root:root 0644`).
5. Run `sh test.sh` to verify the full build.

### Adding a remote service

An api-daemon remote service (child daemon plus JS client) is one call:

```python
from patchlib import FILES, install_remote_service

install_remote_service(
    "MyService",
    daemon=FILES / "myservice-daemon",
    client=FILES / "myservice-service.js.gz",
)
```

It places the daemon in `/system/kaios/remote/MyService/daemon`, the client in
`/system/kaios/http_root/api/v1/myservice/service.js.gz` and registers the
`myservice` permission, which applications must declare in their manifest
(`b2g_features.permissions`) to be granted it.

The daemon runs from a copy of the payload under `/data/local/service/api-daemon`.
The patched `api-daemon.sh` compares the remote services shipped in the image
against that copy on every boot and copies them when they differ, so a new
service or a new version reaches the device with a plain image flash. The
payload itself (daemon binary, `http_root`, config) is rebuilt only when the
copy is missing (first boot, after formatting `userdata`) or when the image
ships a newer daemon version.

## Local testing with act

`test.sh` runs the workflow with act:

```sh
sh test.sh
```

By default the build downloads ~2.3 GB (`emmc.img.xz`) plus the patched
binaries from GitHub releases on every run. To avoid this, point
`LOCAL_SOURCE_DIR` at a directory containing the build files; `test.sh`
mounts it read-only into the act container and `build.sh` copies from it
instead of downloading.

The mirror is a cache of those downloads. Refresh it whenever one of the
releases changes (a new OStore version, for example) - a stale mirror silently
makes local builds differ from CI:

```sh
tools/download-resources.sh "$LOCAL_SOURCE_DIR" --download
```

`tools/download-resources.sh <target-dir> [--download]` is the one place the
download URLs live: `build.sh` calls it with `downloads/` and uses the mirror
when it is available, and `--download` ignores the mirror and fetches from the
release URLs, which is what refreshing the cache needs. Files the server
reports as unchanged are not fetched again.

### Setup

1. Copy `.env.example` to `.env.local`:

   ```sh
   cp .env.example .env.local
   ```

2. Edit `LOCAL_SOURCE_DIR` to a directory holding:

   ```
   emmc.img.xz
   init
   su
   appscmd
   ostore.zip
   ```

   `.env.local` is gitignored, so your local paths never enter commits.

3. Run `sh test.sh`. The act container gets `LOCAL_SOURCE_DIR` mounted at
   `/local-src` (read-only) and the workflow passes it to `build.sh`, which
   copies each file from there before attempting any download. Files that
   are missing from the mirror are downloaded from the network as usual, so
   a partial mirror still works.

### Notes

- The container must be able to loop-mount the image (`--privileged`),
  which is why `test.sh` passes `--container-options "--privileged
  --network host"`.
- `test.sh` unpacks the built image to the parent of the project directory
  (i.e. `../system-patched.img`). Clear that file when changing patches.
- The mirror directory is mounted read-only, so the container cannot modify
  your files.
- Compressing a plain `emmc.img` as `emmc.img.xz` once (about 4 minutes
  with `xz -0 -T0`) saves ~3.2 GB of download per test run.

## CI behavior

On GitHub, `release.yml` runs without `ACT_LOCAL_TEST` and downloads every
file from the official release URLs; `LOCAL_SOURCE_DIR` is only set by
local act runs.
