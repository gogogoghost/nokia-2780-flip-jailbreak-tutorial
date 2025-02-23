## Nokia 2780 flip jailbreak tutorial

This tutorial can lead you to jailbreak your nokia 2780 flip. Include sideload apps and root.

### Flash recovery (Once)

Download all images from [here](https://github.com/gogogoghost/nokia-2780-flip-jailbreak-tutorial/releases/tag/weeknd-toolbox). These precompiled images are from [weeknd-toolbox](https://git.abscue.de/affe_null/weeknd-toolbox/).

Reboot the device and press volume down while booting to enter fastboot.

Connect the device to your PC and use fastboot command to flash these images.

```bash
fastboot oem sudo
fastboot flash avb_custom_key pkmd.bin
fastboot flash vbmeta vbmeta.img
fastboot flash recovery lk2nd.img
```

### Enter recovery

Reboot device and press volume up while booting. You will see the warning screen. Press power key twice can skip it. Or you need to wait for some seconds.

After the warning screen disappear. Press volume up again until the device enter weeknd toolbox.

#### Disable encryption

This operation will erase all user data.

Select "Disable encryption" and follow the on-screen instructions.

#### Mount whole emmc

Select "USB storage" then "Whole eMMC". Your PC can access the whole emmc now.

### Flash kernel (Once)

Donwload boot.img from [here](https://github.com/gogogoghost/nokia-2780-flip-jailbreak-tutorial/releases/tag/patched-files) then flash it.

Patched boot partition has been replaced the kernel cmdline from **androidboot.selinux=enforcing** to **androidboot.selinux=permissive**

```bash
sudo dd if=boot.img of=/dev/sda13
```

### Place adb key

You can use **adb keygen** to generate a new adb key or using the key from this repo.

```bash
# mount userdata
mkdir userdata
sudo mount /dev/adb54 userdata

# copy adbkey
sudo cp adbkey.pub userdata/misc/adb/adb_keys
sudo setfattr -n security.selinux -v u:object_r:system_data_file:s0 userdata/misc/adb/adb_keys

# umount userdata
sudo umount userdata
```

If you cannot mount userdata. Maybe you just did "Disable encryption". Format it.

```bash
sudo mkfs.f2fs /dev/sda54 -f
```

### Flash system

Download system.img from [here](https://github.com/gogogoghost/nokia-2780-flip-jailbreak-tutorial/releases/latest) then flash it.

```bash
sudo dd if=system.img of=/dev/sda16
```

Reboot the device when finished.

### Enable adb

Enable "Settings -> Storage -> USB storage". Then your PC can discovery a adb device.

Use the adb key to connect to it.

```bash
export export ADB_VENDOR_KEYS=$(YOUR_ADBKEY_PATH)
adb shell
```

### Sideload apps

Now you can sideload app by [appscmd](https://github.com/gogogoghost/appscmd) cli via adb. The way by apps will come soon.

```bash
adb shell

# install a app
appscmd install /data/local/tmp/application.zip

# install a pwa
appscmd install-pwa https://xxx.com/manifest.webmanifest

# list apps
appscmd list
```