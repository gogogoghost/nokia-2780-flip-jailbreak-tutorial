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
- `patches/` — one script per feature. Each script modifies exactly one
  thing inside the mounted system partition, so individual patches can be
  reviewed, disabled (delete or rename the file), or extended without
  touching the others.
- `patches/lib.sh` — shared helpers used by patch scripts. `build.sh`
  sources it before running each patch, so patch files contain only their
  own logic and never load the helpers themselves.
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

`build.sh` exports the following variables and injects the helpers for every patch script, so patches never load anything themselves:

| Variable | Meaning |
|---|---|
| `SYSTEM_ROOT` | mounted system partition; all patches write here |
| `PROJECT_DIR` | repository root |
| `FILES_DIR` | repository `files/` directory |
| `DOWNLOAD_DIR` | `downloads/` directory (init, su, appscmd, ostore.zip) |
| `PATCH_LIB` | path to `patches/lib.sh` (already sourced before the patch body runs) |

Before running each patch, `build.sh` sources `patches/lib.sh`, which
defines the helpers used by patches:

- `set_file_metadata <owner:group> <mode> <path>` — set ownership and mode inside `$SYSTEM_ROOT`.
- `json_update <file> <jq-filter>` — atomically rewrite a JSON file with jq.
- `patch_omni_file <archive> <entry> <replacement>` — replace one entry inside `omni.ja`.

### Adding a patch

1. Create `patches/NN-name.sh` with a number higher than the existing ones.
2. Use `$SYSTEM_ROOT`, `$FILES_DIR`, `$DOWNLOAD_DIR` and the helpers above directly — no sourcing, no environment setup.
3. Write only to `$SYSTEM_ROOT`.
4. Set ownership and modes on every file you add — the stock image has
   strict metadata (e.g. binaries `root:2000 0755`, configs `root:root
   0644`). Use `set_file_metadata` from `lib.sh`.
5. Run `sh test.sh` to verify the full build.

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
