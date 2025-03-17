## Nokia 2780 flip jailbreak tutorial

This tutorial can lead you to jailbreak your nokia 2780 flip. Include sideload apps and root.

### Screenshot

Image from this repository contains [ostore](https://github.com/gogogoghost/ostore) to sideload apps. If you uninstalled it. You can do factory reset (format data) or using [appscmd](#sideload-apps) to reinstall.

![1](imgs/ostore_1.png)
![2](imgs/ostore_2.png)
![3](imgs/ostore_3.png)
![4](imgs/ostore_4.png)

### Flash recovery

Download all images from [here](https://github.com/gogogoghost/nokia-2780-flip-jailbreak-tutorial/releases/tag/weeknd-toolbox). These precompiled images are from [weeknd-toolbox](https://git.abscue.de/affe_null/weeknd-toolbox/).

Reboot the device and press volume down while booting to enter fastboot.

Connect the device to your PC and use fastboot command to flash these images.

```bash
fastboot oem sudo
fastboot flash avb_custom_key pkmd.bin
fastboot flash vbmeta vbmeta.img
fastboot flash recovery lk2nd.img
```

### Flash boot

Donwload boot.img from [here](https://github.com/gogogoghost/nokia-2780-flip-jailbreak-tutorial/releases/tag/patched-files) then flash it.

Patched boot partition has been replaced the kernel cmdline from **androidboot.selinux=enforcing** to **androidboot.selinux=permissive**

```bash
fasboot flash boot boot.img
```

### Flash system

Download system.img from [here](https://github.com/gogogoghost/nokia-2780-flip-jailbreak-tutorial/releases/latest) then flash it.

```bash
fastboot flash system system.img
```

### Format data

```bash
fastboot format userdata
```

### How to enter recovery

Reboot device and press volume up while booting. You will see the warning screen. Press power key twice can skip it. Or you need to wait for some seconds.

After the warning screen disappear. Press volume up again until the device enter weeknd toolbox.

### Adb

Enable "Settings -> Storage -> USB storage". Then your PC can discovery a adb device.

Due to the adbd cannot exchange key. This image contains a pre generated key at **/data/misc/adb/adb_keys**.

You need to use the adb key in this repository to connect to it.

```bash
export export ADB_VENDOR_KEYS=$(REPOSITORY_DIR)/adbkey
adb shell
```

Or you can replace the key by yourself.

System will restore the adb key if **/data/misc/adb/adb_keys** not exist during boot.

### Sideload apps

Now you can sideload apps by [appscmd](https://github.com/gogogoghost/appscmd) cli via adb.

```bash
adb shell

# install a app
appscmd install /data/local/tmp/application.zip

# install a pwa
appscmd install-pwa https://xxx.com/manifest.webmanifest

# list apps
appscmd list
```