# Screencapture

Permission gated screen recording for KaiOS 3.1, exposed to applications as an
api-daemon remote service.

Only applications whose token carries the **`screencapture`** permission can
create the service (enforced by the daemon through the generated
`check_service_permission`, and re-checked per method). Sessions opened over the
api-daemon UDS (root tools) bypass permission checks, like every other service.

**A recording belongs to the daemon, not to the page that started it.** The child
daemon is a separate process that api-daemon keeps alive and reuses, so a
recording keeps running when the application is closed, navigated away or
killed. Come back later and `isRecording()`/`elapsed()` still describe it, and
`getBlob()` hands back the whole thing.

## API

The service identifier is `Screencapture` (see *Naming* below); the permission
and the client URL are lower case.

| Method | Returns | Description |
|---|---|---|
| `record(bitrate)` | `bool, str` | start recording at `bitrate` bit/s. A recording that is already running is left alone |
| `stop()` | `bool, str` | stop and wait for the MP4 to be finished |
| `isRecording()` | `bool` | whether a recording is running |
| `elapsed()` | `float` | seconds recorded: live while recording, final once stopped, 0 before anything was recorded |
| `getBlob()` | `binary, str` | the finished MP4 |

`getBlob()` fails while a recording is still running, and when there is nothing
to hand back. It deletes `/data/local/tmp/screencapture.mp4` (and the helper
files next to it) after reading it, so a recording can only be collected once.

`elapsed()` returns 0 until the recorder has published its first second, which is
about a second after `record()` returns.

Recording is 240x320 H.264 at the panel rate (29 fps), video only — there is no
audio track.

### Client usage

```html
<script src="http://127.0.0.1/api/v1/shared/core.js"></script>
<script src="http://127.0.0.1/api/v1/shared/session.js"></script>
<script src="http://127.0.0.1/api/v1/screencapture/service.js"></script>
<script>
navigator.b2g.externalapi.getToken().then((token) => {
  const session = new lib_session.Session();
  session.open('websocket', '127.0.0.1', token, {
    onsessionconnected() {
      lib_screencapture.Screencapture.get(session).then(async (screencapture) => {
        await screencapture.record(1500000);       // bits per second

        // the page may go away here; the recording continues
        console.log(await screencapture.isRecording());
        console.log(await screencapture.elapsed());

        await screencapture.stop();
        const blob = await screencapture.getBlob();
        const url = URL.createObjectURL(new Blob([blob], { type: 'video/mp4' }));
      });
    },
  }, true);
});
</script>
```

The application manifest must declare the permission:

```json
"b2g_features": { "permissions": { "screencapture": {} } }
```

## How it works

The capture is done by `kcap` (see `kcap.c`), the on-device recorder that reads
the display buffers straight out of the HWC HAL and encodes H.264 with the Venus
video processor. The daemon is only a wrapper: it starts kcap, follows its state
files and reads the result.

kcap needs root — it ptraces the HAL to reach the buffers — but a child daemon
runs as uid `10000 + <service id>`. So the daemon starts it through
`/system/xbin/su`, the helper the jailbreak already installs for adb. That
grants root without a prompt, even to a process with no terminal.

Talking to kcap needs no protocol: it already publishes what the service needs
next to its output file.

```
su -c "/system/xbin/kcap rec --mp4 --bitrate=<n> --progress=1 \
       /data/local/tmp/screencapture.mp4 0 29"
```

| Path | Purpose |
|---|---|
| `/data/local/tmp/screencapture.mp4` | the recording |
| `/data/local/tmp/screencapture.mp4.progress` | `elapsed=<s> frames=<n> fps=<r>`, read by `elapsed()` |
| `/data/local/tmp/screencapture.mp4.stop` | created by `stop()`, which kcap treats as "finish cleanly" |
| `/data/local/tmp/screencapture.log` | kcap's own output; the last line explains a failed `record()` |

`stop()` is a request, not a kill: kcap flushes the encoder and writes the MP4's
`moov` atom before exiting, and `stop()` waits for that, so the file is always
playable. `/data/local/tmp` is mode `1777`, so the daemon can create, read and
delete these files itself and only the recorder needs su.

If kcap ever exits on its own (the HAL restarting, say), `isRecording()` notices
and `getBlob()` will hand back whatever was recorded, if anything.

### Where the pixels are

The main panel is a SPI command-mode ST7789Vx2 driven from the panel's own GRAM,
so there is no scanout buffer to read:

* no DRM device (`/sys/class/drm` is absent) and no SurfaceFlinger;
* `/dev/graphics/fb0` is a vestigial `mdss_fb` - its memory is *always zero* and
  filling it with a test pattern never reaches the panel;
* the only full frames live in the HWC HAL
  (`android.hardware.graphics.composer@2.1-service`) as a ring of 240x320 RGB565
  ION dma-bufs, stride 512, 163840 bytes each.

Those buffers cannot be read from outside the HAL: their fds are `anon_inode` so
`/proc/<pid>/fd` cannot reopen them, `/proc/<pid>/map_files` returns `ENXIO`, and
`/proc/<pid>/mem` (and therefore `process_vm_readv` / `PTRACE_PEEKDATA`) returns
**EIO** for the mappings because `ion_vm_ops` has no `->access` vm_op.

### How `kcap` gets them

`kcap` (source `kcap.c`) borrows the HAL's own address space instead of reading
it. It `PTRACE_ATTACH`es, finds a real `svc #0` in the target, and executes
ordinary syscalls *in the target's context* by pointing its PC at that
instruction - restoring the original registers before detaching. Nothing is
patched, no code is injected, and only `/data` is written.

For each frame it injects, per display buffer:

1. `ioctl(fd, DMA_BUF_IOCTL_SYNC, {START,READ})` - without this the CPU mapping
   serves stale cache lines and the recording freezes on the first frame;
2. `write(fifo_fd, buffer_addr, 163840)` - the target copies the frame itself.

The FIFO is `/data/local/tmp/kcap.fifo`, a real named pipe, so the frames arrive
in memory with no disk I/O; the reader keeps whichever buffer changed, repacks
the 512-byte stride to a packed 240x320 RGB565 frame and appends it to the
output. `kcap` creates the FIFO itself and removes it again on every exit path
(including SIGINT/SIGTERM), so a recording needs no adb-side cleanup.

`kcap` re-attaches per frame so the HAL runs free in between, and reconnects
automatically if the HAL restarts (in `--mp4` mode a restart ends the recording
instead, since one MP4 cannot span two HAL lifetimes). Encode by hand with:

```
ffmpeg -f rawvideo -pixel_format rgb565le -video_size 240x320 \
       -framerate 29 -i out.raw -pix_fmt yuv420p out.mp4
```

### Stopping an open-ended recording

`kcap rec ... <out> 0 <fps>` records until it is told to stop. A stop request
does not kill the process: it asks the main loop to break, so the encoder is
flushed and the MP4 still gets a valid `moov` atom. There are two ways to ask:

* **a signal** — `SIGINT`, `SIGTERM` or `SIGHUP`, which is what Ctrl-C or
  `kill` gives you. The first one stops gracefully; a second one gives up on the
  clean exit and removes the FIFO on the way out.
* **`<out>.stop`** — creating that file stops the recording. It is the way to
  stop a recorder that was started detached and has no terminal. A stale file is
  deleted when the recording starts, so it always means "stop from here on".

The FIFO is always removed by the binary itself, whichever path is taken, so
nothing has to be cleaned up over adb.

### Progress

`--progress[=N]` reports every N seconds (default 1) how long the recording has
been running:

* a line on stderr — `kcap: 12.4s elapsed, 357 frames (28.9 fps)` — which is
  what you see in a terminal, or in the log of a detached run;
* the same numbers as `elapsed=<s> frames=<n> fps=<r>` in `<out>.progress`, for
  a host script to poll without having to parse that log. The file is removed
  when the recording ends.

Off by default, so short clips stay quiet. `tools/kaios-screenrec.sh` turns it on
automatically for an open-ended recording and prints the elapsed time live;
finite runs capture kcap's output and only print it at the end, so there the
flag is only useful when driving `kcap` directly.

### Encoding on the device (`--mp4`)

`--mp4` makes `kcap` produce a finished MP4 itself, so nothing but the encoded
stream crosses adb. The frames are handed to the platform encoder:

```
display buffers -> RGB565 (240x320, stride 512) -> NV12 -> AMediaCodec -> AMediaMuxer
```

The encoder is the **Venus video processor**, reached through
`OMX.qcom.video.encoder.avc`; it is not the GPU, whose Adreno block has no video
encode hardware. (`measured-frame-rate-320x240` is 377 fps for that component,
13x what is needed here.) The only thing the GPU could usefully do is the
RGB565 to NV12 conversion, which is a fraction of a millisecond per frame on the
CPU at this resolution.

This needs `libmediandk`, which is a system shared library and cannot be linked
statically, so `kcap` is **dynamically linked** and must be built with `clang++`
(the NDK's media headers do not compile as C). Audio is not captured; the output
is video only.

`--bitrate=N` (bit/s, optional `k`/`M` suffix) sets the target handed to the
encoder; the default is 1500000, which is comfortably above what a 240x320
screen needs. It behaves as a ceiling rather than a constant: a static screen
encodes to whatever the content costs. Measured on a static screen, `200k`
produced 242 kbit/s while `2.5M` and `4M` both landed near 650-700 kbit/s,
because at that point the content, not the target, was the limit.

Note that `kcap` writes the NV12 frame as packed 240x320 into the codec's input
buffer. That layout is not documented anywhere on this build — there is no
`AMediaCodec_getInputImage` in the device's `libmediandk`, and the reported input
buffer capacity (143360, not the 115200 a packed frame needs) is not a reliable
guide — so it was confirmed by decoding the result and comparing it against a raw
capture (mean absolute difference 1.09/255, i.e. H.264 loss only).

## Recording from a computer

`tools/kaios-screenrec.sh <seconds> [fps] [output] [--mp4] [--bitrate=N]` drives
`kcap` from the host and writes an `.mp4`, `.gif` or `.raw`. It is a convenience
wrapper: it pushes `dist/kcap` to the device, starts it, pulls the result and
encodes it.

By default the raw RGB565 frames are pulled and encoded on the host. With
`--mp4` the device encodes H.264 itself, so only the finished file crosses adb
(~300 kbit/s instead of ~4.5 MB/s) — use it for anything but short clips.
`--bitrate=N` sets the encoder target for that path (bit/s, `k`/`M` suffix
allowed, default 1500000); it is a ceiling, not a guarantee, since a static
screen simply produces fewer bits.

A `seconds` of `0` or less records until stopped. Pressing Ctrl-C on the script
asks the device to finish, waits for it, and then pulls the result; the device
can equally be stopped out of band with `adb shell "touch <out>.stop"` or a
signal.
## Naming

The permission, the client URL and the JS global are all lower case
(`screencapture`, `/api/v1/screencapture/service.js`, `lib_screencapture`), but
the **service identifier is `Screencapture`**. api-daemon's codegen camel cases
the SIDL service name, and the daemon directory has to match that value exactly
because the child compares it against the generated `SERVICE_NAME`. An all lower
case SIDL name generates a mix of `screencaptureFromClient` and
`ScreencaptureToClient` and does not compile.

## Layout

```
kcap.c                 the on-device recorder (also built by tools/kaios-screenrec.sh)
src/screencapture.sidl API definition (service Screencapture: ScreencaptureFactory)
src/service.rs         service implementation (permission checks + shared state)
src/backend.rs         starting kcap, reading its state files
daemon/                child daemon crate, spawned by api-daemon
client/                esbuild bundling of the generated JS client
build.sh               builds all three artifacts into dist/
dist/daemon            child daemon (committed)
dist/kcap              on-device recorder (committed)
dist/service.js.gz     JS client (committed)
```

## Build

```sh
ANDROID_NDK=$HOME/Android/Sdk/ndk/r21e services/Screencapture/build.sh
```

`SKIP_KCAP=1` or `SKIP_CLIENT=1` skip those artifacts. kcap is built with the
NDK alone; the daemon is built inside a pinned api-daemon checkout under
`services/.cache/api-daemon`, like the other services.

One host wrinkle: `common` declares `#[link(name = "selinux")]` and is also
built for the host, for the build scripts. On a distribution without a host
libselinux that link fails, so `build.sh` provides a link-only stub under
`services/.cache/host-libs` — build scripts only use the codegen helpers and
never call `security_getenforce()`. That keeps the build root-free.

## Deployment

`images/system/12-api-daemon-services.py` installs the daemon and the JS client
into `/system/kaios`, installs `dist/kcap` as `/system/xbin/kcap`, and registers
the `screencapture` permission in Gecko's `PermissionsTable` (granted to packaged
and core applications that declare it). The patched launcher syncs the service
under `/data/local/service/api-daemon/` on boot.
