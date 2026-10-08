#!/bin/sh
# kaios-screenrec.sh — record the screen of a Nokia 2780 (KaiOS 3.1) at 29 fps.
#
# Capture is done by `tools/kcap`, the on-device recorder that reads the display
# buffers straight out of the HWC HAL. See contributor.md ("Screen recording")
# for why that is the only place the pixels exist.
#
# usage: kaios-screenrec.sh <seconds> [fps] [output] [--mp4] [--bitrate=N]
#   seconds 0 or less records until you stop it: press Ctrl-C and the script
#           asks the device to finish cleanly, then pulls the result
#   fps     default 29 (the panel rate)
#   output  default screen.mp4
#     *.mp4 / *.mkv  H.264 video          (needs ffmpeg unless --mp4)
#     *.gif          animated GIF         (needs ffmpeg)
#     *.raw          packed RGB565 frames (no ffmpeg needed)
#   --mp4   have the device encode H.264 itself (Venus VPU) and pull the
#           finished file (~300 kbit/s) instead of ~4.5 MB/s of raw frames.
#           Use it for anything but short clips; it is also much faster over
#           adb. `*.raw` is not available with --mp4.
#   --bitrate=N  encoder bitrate in bit/s, with a k or M suffix allowed
#           (e.g. --bitrate=800k). Needs --mp4. Use one token, not
#           "--bitrate 800k"; default 1500000.
#   In the open-ended mode the script always passes --progress=1, so the
#   elapsed time is shown while recording and written to <out>.progress.
#
# Requires: adb (and ffmpeg unless the output is *.raw or --mp4 to *.mp4).

set -e

mp4=0
extra=""
for a in "$@"; do
  case "$a" in
    --mp4) mp4=1 ;;
    --bitrate=*) extra="$extra $a" ;;
    --bitrate) echo "--bitrate needs a value: use --bitrate=800k" >&2; exit 2 ;;
  esac
done

secs=${1:?usage: kaios-screenrec.sh <seconds> [fps] [output] [--mp4]}
fps=${2:-29}
out=${3:-screen.mp4}
case "$out" in --*) out=screen.mp4 ;; esac

if [ "$mp4" = 1 ] && [ "${out##*.}" = "raw" ]; then
  echo "--mp4 cannot produce .raw frames; drop --mp4 for that" >&2
  exit 2
fi

# seconds <= 0 means "until told to stop"
unlimited=0
case "$secs" in
  0|0.0|inf|infinite|-*) unlimited=1 ;;
esac

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
local_dir=$(mktemp -d)
cleanup() { rm -rf "$local_dir"; }
trap 'cleanup' EXIT

# kcap now belongs to the screencapture remote service, which builds it too.
bin="$here/../services/Screencapture/dist/kcap"
if [ ! -x "$bin" ]; then
  echo "missing $bin" >&2
  echo "build: services/Screencapture/build.sh" >&2
  echo "       (or just kcap: \$NDK/armv7a-linux-androideabi29-clang++ -O2 -x c++ \\" >&2
  echo "         -D_FILE_OFFSET_BITS=64 -o services/Screencapture/dist/kcap \\" >&2
  echo "         services/Screencapture/kcap.c -lmediandk -llog -pthread)" >&2
  exit 1
fi

remote=/data/local/tmp/kcap
if [ "$mp4" = 1 ]; then
  remote_out=/data/local/tmp/kcap.mp4
  flag="--mp4"
else
  remote_out=/data/local/tmp/kcap.raw
  flag=""
fi
log=/data/local/tmp/kcap.log

adb push "$bin" "$remote" >/dev/null 2>&1
adb shell "chmod 755 $remote" >/dev/null 2>&1
adb shell "rm -f $remote_out $remote_out.stop $log" >/dev/null 2>&1

if [ "$unlimited" = 1 ]; then
  # ask the recorder to publish its clock so this script can show it live
  case "$extra" in
    *--progress*) ;;
    *) extra="$extra --progress=1" ;;
  esac

  echo "recording at $fps fps until you press Ctrl-C ($flag on device)..."
  # detached on the device, so stopping is our decision rather than adb's
  adb shell "(nohup $remote rec $flag $extra $remote_out 0 $fps > $log 2>&1 &)" >/dev/null 2>&1

  alive() { [ -n "$(adb shell pidof kcap 2>/dev/null | tr -d '\r')" ]; }

  # <out>.progress is both the clock and a liveness check, in one round trip
  poll() {
    adb shell "if pidof kcap >/dev/null 2>&1; then echo ALIVE; \
               cat $remote_out.progress 2>/dev/null; else echo GONE; fi" 2>/dev/null |
      tr -d '\r'
  }

  stop_recording() {
    trap '' INT TERM
    printf '\nstopping (asking the device to finish)...\n'
    adb shell "touch $remote_out.stop" >/dev/null 2>&1
    while alive; do sleep 0.3; done
  }
  trap 'stop_recording' INT TERM

  sleep 1
  if tty >/dev/null 2>&1; then
    while :; do
      pstat=$(poll)
      case "$pstat" in GONE*) break ;; esac
      el=$(printf '%s\n' "$pstat" | sed -n 's/.*elapsed=\([0-9.]*\).*/\1/p')
      [ -n "$el" ] && printf '\r  recording %ss' "$el"
      sleep 1
    done
    [ -n "$el" ] && printf '\r  recorded %ss\n' "$el"
  else
    while alive; do sleep 1; done
  fi
  trap 'cleanup' INT TERM
  info=$(adb shell "cat $log" 2>&1 | tr -d '\r')
else
  echo "recording $secs s at $fps fps ($flag on device)..."
  info=$(adb shell "$remote rec $flag $extra $remote_out $secs $fps 163840" 2>&1 | tr -d '\r')
fi

# the log of an open-ended run also carries one progress line per second
info=$(printf '%s\n' "$info" | grep -v 'kcap: .*s elapsed,')
echo "device: $info"
case "$info" in *"frames written"*) ;; *) echo "capture failed" >&2; exit 1 ;; esac

adb pull "$remote_out" "$local_dir/cap" >/dev/null 2>&1
adb shell "rm -f $remote_out $remote_out.stop $log" >/dev/null 2>&1 || true

# only the summary line carries the true frame count and rate
summary=$(printf '%s\n' "$info" | grep 'frames written' | tail -1)
got=$(printf '%s\n' "$summary" | sed -n 's/.*: \([0-9]*\) frames written.*/\1/p')
eff=$(printf '%s\n' "$summary" | sed -n 's/.*(\([0-9.]*\) fps).*/\1/p')
[ -n "$eff" ] || eff=$fps
echo "captured $got frames ($eff fps effective)"

if [ "$mp4" = 1 ]; then
  case "$out" in
    *.gif)
      command -v ffmpeg >/dev/null 2>&1 || { cp "$local_dir/cap" ./screen.mp4
        echo "ffmpeg not found; MP4 in ./screen.mp4" >&2; exit 1; }
      ffmpeg -loglevel error -y -i "$local_dir/cap" \
             -vf "fps=$eff,split[a][b];[a]palettegen[p];[b][p]paletteuse" "$out" ;;
    *)
      cp "$local_dir/cap" "$out" ;;
  esac
  echo "wrote $out ($(du -h "$out" 2>/dev/null | cut -f1))"
  exit 0
fi

case "$out" in
  *.raw)
    cp "$local_dir/cap" "$out"
    echo "wrote $out ($(du -h "$out" | cut -f1))"
    exit 0 ;;
esac

if ! command -v ffmpeg >/dev/null 2>&1; then
  cp "$local_dir/cap" ./screen.raw
  echo "ffmpeg not found; raw frames in ./screen.raw" >&2
  exit 1
fi

case "$out" in
  *.gif)
    ffmpeg -loglevel error -y -f rawvideo -pixel_format rgb565le \
           -video_size 240x320 -framerate "$eff" -i "$local_dir/cap" \
           -vf "split[a][b];[a]palettegen[p];[b][p]paletteuse" "$out" ;;
  *)
    ffmpeg -loglevel error -y -f rawvideo -pixel_format rgb565le \
           -video_size 240x320 -framerate "$eff" -i "$local_dir/cap" \
           -vf "scale=480:640:flags=neighbor" -pix_fmt yuv420p -crf 18 "$out" ;;
esac
echo "wrote $out ($(du -h "$out" 2>/dev/null | cut -f1))"
