# services/

Remote services for the patched Nokia 2780 system image.

Each subdirectory is **one** api-daemon remote service:

```
services/<ServiceName>/          # directory name MUST equal the SIDL service name
    src/<name>.sidl              # API definition (sidl)
    src/service.rs               # implementation
    daemon/                      # child daemon crate, spawned by api-daemon
    client/                      # JS client bundle build (esbuild)
    build.sh                     # builds both artifacts into dist/
    dist/daemon                  # committed: installed as
                                 #   /system/kaios/remote/<ServiceName>/daemon
    dist/service.js.gz           # committed: installed as
                                 #   /system/kaios/http_root/api/v1/<name>/service.js.gz
```

A service may ship further committed artifacts in `dist/`; Screencapture adds
`dist/kcap`, the recorder its daemon runs. The install patch decides where those
go.

## How remote services work

`api-daemon` scans `/data/local/service/api-daemon/remote/` at startup. Every
subdirectory is registered as a remote service; the first time an application
calls `get_service("<ServiceName>", <fingerprint>)` the daemon forks
`remote/<ServiceName>/daemon` (uid/gid `10000 + id`, SELinux `child-daemon`,
`IPC_FD` inherited) and relays the service protocol over that socket.

Hard rules (all verified on device):

- **The directory name must equal the SIDL `service` name** (case sensitive).
  The name is passed to the child, which compares it against `SERVICE_NAME`.
- The child is **not root** (uid `10000 + id`), its working directory is its own
  service directory (`LD_LIBRARY_PATH` points there too).
- Services are spawned lazily on the first `get_service`, then reused.
- A service annotated with `#[permission=<name>]` is only handed to clients
  whose token carries that permission; `uds` sessions bypass all checks.

## Build

The service crates depend on the api-daemon sources (`common`, `codegen`,
vendored crates and workspace patches), so they are built **inside a pinned
api-daemon checkout**, which `build.sh` materializes under
`services/.cache/api-daemon`. Build artifacts are committed to `dist/` so the
image build does not need a Rust/NDK toolchain.

```sh
ANDROID_NDK=$HOME/Android/Sdk/ndk/r21e services/Sideload/build.sh
ANDROID_NDK=$HOME/Android/Sdk/ndk/r21e services/Screencapture/build.sh
```

`common` declares `#[link(name = "selinux")]` and is also built for the host,
for the build scripts, which needs a host libselinux. `build.sh` supplies a
link-only stub when the distribution has none, so no root and no
`libselinux-devel` are required.

## Deployment

`patches/12-<name>.sh` copies the artifacts into the system partition:

- `/system/kaios/remote/<ServiceName>/daemon` — child daemon
- `/system/kaios/http_root/api/v1/<name>/service.js.gz` — JS client bundle

and `images/system/payload/api-daemon.sh` (the patched boot script) copies them into the
runtime directory `/data/local/service/api-daemon/` on every boot.
