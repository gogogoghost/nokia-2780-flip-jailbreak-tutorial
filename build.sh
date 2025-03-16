#!/bin/sh

set -e

output="output"
mkdir $output

echo "Download emmc image..."
wget https://github.com/gogogoghost/nokia-2780-flip-jailbreak-tutorial/releases/download/emmc/emmc.img.xz -O emmc.img.xz
# wget http://127.0.0.1:8000/emmc.img.xz -O emmc.img.xz

echo "Download init..."
wget https://github.com/gogogoghost/nokia-2780-flip-jailbreak-tutorial/releases/download/patched-files/init -O init

echo "Download su..."
wget https://github.com/gogogoghost/nokia-2780-flip-jailbreak-tutorial/releases/download/su/su -O su

echo "Download appscmd..."
wget https://github.com/gogogoghost/appscmd/releases/download/0.1.0/appscmd -O appscmd

echo "Download ostore..."
wget https://github.com/gogogoghost/ostore/releases/download/1.0.2/ostore.zip -O ostore.zip

echo "Decompress..."
xz -d emmc.img.xz

loDev=$(losetup -f)
echo "Losetup $loDev..."
losetup -P $loDev emmc.img

mkdir sys
mount ${loDev}p16 sys

echo "Copy files..."

# copy init
cp init sys/system/bin/init

# overwrite init.usb.configfs.rc
cp files/init.usb.configfs.rc sys/

# copy su
cp su sys/system/xbin/
chmod +x sys/system/xbin/su
cp files/init.sud.rc sys/system/etc/init/

# copy appscmd
cp appscmd sys/system/xbin/
chmod +x sys/system/xbin/appscmd
cp files/init.appscmd.rc sys/system/etc/init/

# install ostore
mkdir -p sys/system/b2g/webapps/ostore
cp ostore.zip sys/system/b2g/webapps/ostore/application.zip
jq '. += [{"install_time": 1663931969102, "manifest_url": "http://ostore.localhost/manifest.webmanifest","removable": true,"name": "ostore"}]' sys/system/b2g/webapps/webapps.json > temp.json && mv temp.json sys/system/b2g/webapps/webapps.json

echo "Umount system..."
umount sys

echo "Dump system partition..."
dd if=${loDev}p16 of=$output/system.img

echo "Clean..."
losetup -d $loDev

# compress
echo "Compress image..."
xz $output/system.img