# images/

Everything that produces a flashable image from the stock eMMC dump.

```
images/
    system/                  # patches the system partition
        patchlib.py          # shared helpers (see its docstring)
        NN-name.py           # one patch per feature, run in numeric order
        payload/             # files the patches copy into the image
    dtbo/                    # patches the device tree overlay partition
        debounce.py          # keypad debounce
```

## system

`build.sh` mounts the system partition of the stock eMMC image and runs every
`images/system/[0-9]*.py` in numeric order with these variables exported:

| Variable | Meaning |
|---|---|
| `SYSTEM_ROOT` | mounted system partition — every write goes here |
| `PROJECT_DIR` | repository root |
| `FILES_DIR` | `images/system/payload` |
| `SERVICES_DIR` | `services/` (built remote service artifacts live in `services/<Name>/dist/`) |
| `DOWNLOAD_DIR` | `downloads/` (init, su, appscmd, ostore.zip) |

`patchlib.py` provides the helpers — file placement, JSON edits,
`application.zip`/`omni.ja` edits, permission registration, application
installation and remote service installation — and its docstring is the
reference. A patch should use only those helpers, fail loudly when the stock
image does not look the way it expects, and touch exactly one feature, so it can
be reviewed, disabled or reordered on its own.

## dtbo

`images/dtbo/debounce.py` extracts the `dtbo` partition from the stock eMMC dump,
locates the keypad's `debounce-delay-ms` and rewrites it (10 ms → 30 ms: the
stock value sits just below the contact chatter this keypad produces, which made
a single press report twice). The firmware's DTBs do not follow the standard FDT
layout — their header offsets are stale — so the property is located by walking
back from the `input-name` value instead of parsing the tree, and the old value
is asserted so a firmware change fails the build instead of producing a wrong
image.

## Outputs

`build.sh` writes `output/system-patched.img` and `output/dtbo.img`. The release
workflow publishes both, and the readme documents how to flash them.
