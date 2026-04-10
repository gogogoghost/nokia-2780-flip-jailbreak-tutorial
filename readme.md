## Nokia 2780 flip jailbreak tutorial

This guide covers recovery, root, ADB, and app sideloading on the Nokia 2780 Flip.

### Patched system image

The patched `system.img` from this repository:

1. disables SELinux enforcement
2. includes root, and `su` is available from `adb shell`
3. includes [`ostore`](https://github.com/gogogoghost/ostore-solid)
4. includes [`appscmd`](#sideload-apps-via-cli) for command line app installation; this is not the official [`appscmd`](https://github.com/kaiostech/appscmd)
5. attaches ADB to `USB storage and ADB`, and requires the ADB key from this repository
6. enables the hidden Developer menu entry, including `USB Debugger` and `Remote Debugger`

If `ostore` was removed, reinstall it with a factory reset or with [`appscmd`](#sideload-apps-via-cli).

### Prepare

[recovery images](https://github.com/gogogoghost/nokia-2780-flip-jailbreak-tutorial/releases/tag/weeknd-toolbox) (built from [weeknd-toolbox](https://git.abscue.de/affe_null/weeknd-toolbox/))

[boot.img](https://github.com/gogogoghost/nokia-2780-flip-jailbreak-tutorial/releases/tag/patched-files)

Patched `boot.img` changes the kernel cmdline from `androidboot.selinux=enforcing` to `androidboot.selinux=permissive`.

[system.img](https://github.com/gogogoghost/nokia-2780-flip-jailbreak-tutorial/releases/latest)

### Flash them in fastboot mode

Reboot the device and hold volume down to enter fastboot, then flash:

```bash
# grant permission
fastboot oem sudo

# flash recovery
fastboot flash avb_custom_key pkmd.bin
fastboot flash vbmeta vbmeta.img
fastboot flash recovery lk2nd.img

# flash boot.img
fastboot flash boot boot.img

# flash system.img
fastboot flash system system.img

# format data (first time)
fastboot format userdata
fastboot format cache

# reboot
fastboot reboot
```

For later updates, flashing a new `system.img` is usually enough.

### Adb

Enable `Settings -> Storage -> USB storage and ADB`. Then your PC should detect an ADB device.

This image restores a pre-generated key to `/data/misc/adb/adb_keys`.

Use the key from this repository to connect:

```bash
export ADB_VENDOR_KEYS=$(REPOSITORY_DIR)/adbkey
adb shell
```

You can replace the key with your own if needed.

If `/data/misc/adb/adb_keys` is missing, it will be restored on boot.

### Known issues

- After disabling `USB Debugger` or `Remote Debugger`, the related socket may still remain present, but new connections will fail.

### Sideload apps via cli

The image includes [appscmd](https://github.com/gogogoghost/appscmd) for sideloading.

```bash
adb shell

# install a app
adb push application.zip /data/local/tmp/
appscmd install /data/local/tmp/application.zip

# install a pwa
appscmd install-pwa https://xxx.com/manifest.webmanifest

# list apps
appscmd list
```

### How to enter recovery

Reboot and hold volume up while booting. The warning screen will appear.

Press power twice to skip the warning, or wait a few seconds. Then press volume up again until the device enters weeknd toolbox.
