#!/bin/sh

set -e

output="output"
mkdir $output

echo "Download emmc image..."
# wget https://github.com/gogogoghost/nokia-2780-flip-jailbreak-tutorial/releases/download/emmc/emmc.img.xz -O emmc.img.xz
wget http://127.0.0.1:8000/emmc.img.xz -O emmc.img.xz

echo "Download init..."
wget https://github.com/gogogoghost/nokia-2780-flip-jailbreak-tutorial/releases/download/patched-files/init -O init

echo "Download su"
wget https://github.com/gogogoghost/nokia-2780-flip-jailbreak-tutorial/releases/download/su/su -O su

echo "Decompress..."
xz -d emmc.img.xz

loDev=$(losetup -f)
echo "Losetup $loDev..."
losetup -P $loDev emmc.img

mkdir sys
mount ${loDev}p16 sys

# copy init
cp init sys/system/bin/init

# overwrite init.usb.configfs.rc
cp files/init.usb.configfs.rc sys/

# copy su
cp su sys/system/xbin/
chmod +x sys/system/xbin/su
cp files/init.sud.rc sys/system/etc/init/

echo "Umount system..."
umount sys

echo "Dump system..."
dd if=${loDev}p16 of=$output/system.img

# compress
echo "Compress system..."
xz $output/system.img

echo "Clean..."
losetup -d $loDev