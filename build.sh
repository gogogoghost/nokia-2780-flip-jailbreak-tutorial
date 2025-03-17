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

mkdir root
mount ${loDev}p16 root

echo "Copy files..."

# copy init
cp init root/system/bin/init

# overwrite init.usb.configfs.rc
cp files/init.usb.configfs.rc root/

# copy su
cp su root/system/xbin/
chmod +x root/system/xbin/su
cp files/init.sud.rc root/system/etc/init/

# copy appscmd
cp appscmd root/system/xbin/
chmod +x root/system/xbin/appscmd
cp files/init.appscmd.rc root/system/etc/init/

# install ostore
mkdir -p root/system/b2g/webapps/ostore
cp ostore.zip root/system/b2g/webapps/ostore/application.zip
jq '. += [{"install_time": 1663931969102, "manifest_url": "http://ostore.localhost/manifest.webmanifest","removable": true,"name": "ostore"}]' root/system/b2g/webapps/webapps.json > temp.json && mv temp.json root/system/b2g/webapps/webapps.json

# check adb key when startup
mkdir -p root/system/adb
cp files/init.copy_adb_key.rc root/system/etc/init/
cp files/copy_adb_key root/system/bin/
chmod +x root/system/bin/copy_adb_key
cp adbkey.pub root/system/adb/adb_keys

echo "Umount system..."
umount root

echo "Dump system partition..."
dd if=${loDev}p16 of=$output/system.img

echo "Clean..."
losetup -d $loDev

# compress
echo "Compress image..."
xz -T0 $output/system.img