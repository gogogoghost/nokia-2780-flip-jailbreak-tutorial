#!/system/bin/sh

# api-daemon launcher, patched by the jailbreak tutorial:
#   - the original script only copied the /system/kaios payload when the daemon
#     version changed, and `cp -rf` nested http_root on a re-copy
#   - remote services shipped in the image (/system/kaios/remote and their JS
#     clients) are compared against the runtime copy on every boot and synced
#     when they differ, so flashing a new image is enough to update them

newver=`cat /system/kaios/api-daemon.ver`
oldver=`cat /data/local/service/updater/installed/api-daemon-*.toml 2>/dev/null | grep version | cut -f 2 -d '"'`
newer=0

IFS="." read -a v_a <<< "$newver"
IFS="." read -a v_b <<< "$oldver"

i=0
a=${v_a[$i]}
b=${v_b[$i]}
while [[ -n "$a" || -n "$b" ]]; do
  [[ -z "$a" ]] && a=0
  [[ -z "$b" ]] && b=0
  [[ "$a" -gt "$b" ]] && newer=1 && break
  [[ "$a" -lt "$b" ]] && break

  i=`expr $i + 1`
  a=${v_a[$i]}
  b=${v_b[$i]}
done

API_DAEMON_DIR=/data/local/service/api-daemon
if [ ! -f ${API_DAEMON_DIR}/init -o "$newer" = "1" ]; then
  rm -f ${API_DAEMON_DIR}/init
  mkdir -p ${API_DAEMON_DIR}
  rm -rf ${API_DAEMON_DIR}/http_root
  cp -rf /system/kaios/http_root ${API_DAEMON_DIR}
  cp -f /system/kaios/api-daemon ${API_DAEMON_DIR}
  cp -f /system/kaios/config.toml ${API_DAEMON_DIR}
  cp -f /system/kaios/kota.json ${API_DAEMON_DIR}
  touch ${API_DAEMON_DIR}/init
fi

# Remote services shipped in the image are compared against the runtime copy on
# every boot and copied only when they differ, so flashing a new image is enough
# to update them (the payload copy above runs only when it is rebuilt). `cmp`
# keeps a normal boot free of writes.
for service_dir in /system/kaios/remote/*/; do
  [ -d "$service_dir" ] || continue
  name=`basename "$service_dir"`
  mkdir -p ${API_DAEMON_DIR}/remote/${name}
  cmp -s ${service_dir}daemon ${API_DAEMON_DIR}/remote/${name}/daemon ||
    cp -f ${service_dir}daemon ${API_DAEMON_DIR}/remote/${name}/daemon
  chmod 755 ${API_DAEMON_DIR}/remote/${name}/daemon
done

for client_dir in /system/kaios/http_root/api/v1/*/; do
  [ -f "${client_dir}service.js.gz" ] || continue
  name=`basename "$client_dir"`
  mkdir -p ${API_DAEMON_DIR}/http_root/api/v1/${name}
  cmp -s ${client_dir}service.js.gz ${API_DAEMON_DIR}/http_root/api/v1/${name}/service.js.gz ||
    cp -f ${client_dir}service.js.gz ${API_DAEMON_DIR}/http_root/api/v1/${name}/service.js.gz
done

exec ${API_DAEMON_DIR}/api-daemon ${API_DAEMON_DIR}/config.toml
