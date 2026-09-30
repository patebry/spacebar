#!/bin/bash
# Makes the video and audio test clips: 6 s of testsrc2 with the format and codec burned in and a running clock, over a sine
# tone, so picture, motion and sound can each be checked by eye and ear.
#   make_media.sh <out dir>        FFMPEG=/path/to/ffmpeg (default: /opt/homebrew/bin/ffmpeg, else ffmpeg on PATH)
# Exits 3 when there is no ffmpeg. AMR is written as silent frames: macOS has no AMR encoder (afconvert -d samr never returns)
# and neither has Homebrew's ffmpeg.
set -euo pipefail
out=${1:?usage: make_media.sh <out dir>}
mkdir -p "$out"
FFMPEG=${FFMPEG:-/opt/homebrew/bin/ffmpeg}
[ -x "$FFMPEG" ] || FFMPEG=$(command -v ffmpeg || true)
[ -n "$FFMPEG" ] || { echo "no ffmpeg" >&2; exit 3; }
FONT=/System/Library/Fonts/Supplemental/Arial\ Bold.ttf
[ -f "$FONT" ] || FONT=/System/Library/Fonts/Helvetica.ttc
SECS=6

ff() { "$FFMPEG" -hide_banner -loglevel error -nostdin -y "$@"; }

# video <file> <WxH> <label> <tone Hz> <ffmpeg output args...>
video() {
  local file=$1 size=$2 label=$3 hz=$4; shift 4
  local w=${size%x*} fs
  label=${label//:/\\:}
  fs=$(( w / 18 ))
  ff -f lavfi -i "testsrc2=size=$size:rate=30:duration=$SECS" -f lavfi -i "sine=frequency=$hz:duration=$SECS:sample_rate=48000" \
    -vf "drawtext=fontfile='$FONT':text='$label':fontsize=$fs:fontcolor=white:box=1:boxcolor=black@0.7:boxborderw=$(( fs / 3 )):x=(w-tw)/2:y=h/2-th,drawtext=fontfile='$FONT':text='%{pts\\:hms}':fontsize=$(( fs * 2 / 3 )):fontcolor=yellow:box=1:boxcolor=black@0.7:x=(w-tw)/2:y=h/2+th" \
    -t $SECS "$@" "$out/$file"
  echo "$file"
}

# audio <file> <tone Hz> <ffmpeg output args...>
audio() {
  local file=$1 hz=$2; shift 2
  ff -f lavfi -i "sine=frequency=$hz:duration=$SECS:sample_rate=44100" -t $SECS "$@" "$out/$file"
  echo "$file"
}

video mp4-h264.mp4          1280x720 'MP4 · H.264 · AAC'              440 -c:v libx264 -pix_fmt yuv420p -c:a aac -movflags +faststart
video mp4-hevc.mp4          1280x720 'MP4 · HEVC (hvc1) · AAC'        494 -c:v libx265 -tag:v hvc1 -pix_fmt yuv420p -x265-params log-level=error -c:a aac
video mov-prores422.mov     1280x720 'MOV · ProRes 422 · PCM'         523 -c:v prores_ks -profile:v 2 -pix_fmt yuv422p10le -c:a pcm_s16le
video mov-h264.mov          1280x720 'MOV · H.264 · AAC'              587 -c:v libx264 -pix_fmt yuv420p -c:a aac
video m4v-h264.m4v          1280x720 'M4V · H.264 · AAC'              659 -c:v libx264 -pix_fmt yuv420p -c:a aac -f mp4
video 3gp-h264.3gp          352x288  '3GP · H.264 · AAC'              698 -c:v libx264 -profile:v baseline -pix_fmt yuv420p -c:a aac -ar 22050 -ac 1 -b:a 48k
video mpg-mpeg2.mpg         720x480  'MPG · MPEG-2 PS · MP2'          784 -c:v mpeg2video -b:v 4M -c:a mp2 -f vob
video m2v-mpeg2.m2v         720x480  'M2V · MPEG-2 elementary (silent)' 880 -an -c:v mpeg2video -b:v 4M -f mpeg2video
video webm-vp9.webm         1280x720 'WEBM · VP9 · Opus'              988 -c:v libvpx-vp9 -b:v 1M -deadline realtime -cpu-used 8 -c:a libopus
video mkv-h264.mkv          1280x720 'MKV · H.264 · AAC'              1047 -c:v libx264 -pix_fmt yuv420p -c:a aac
video avi-mjpeg.avi         640x480  'AVI · MJPEG · PCM'              1175 -c:v mjpeg -q:v 5 -pix_fmt yuvj420p -c:a pcm_s16le
video portrait-9x16.mp4     720x1280 'PORTRAIT 9:16 · H.264'          1319 -c:v libx264 -pix_fmt yuv420p -c:a aac
video 4k-hevc.mov           3840x2160 '4K UHD · HEVC (hvc1) · MOV'    392 -c:v libx265 -tag:v hvc1 -pix_fmt yuv420p -preset ultrafast -x265-params log-level=error -c:a aac

audio audio-mp3.mp3   440 -c:a libmp3lame -b:a 128k
audio audio-aac.m4a   494 -c:a aac -b:a 128k
audio audio-book.m4b  523 -c:a aac -b:a 64k -f ipod
audio audio-pcm.wav   587 -c:a pcm_s16le
audio audio-pcm.aiff  659 -c:a pcm_s16be
audio audio-flac.flac 698 -c:a flac
audio audio-vorbis.ogg 784 -c:a libvorbis
audio audio-opus.opus 880 -c:a libopus -b:a 64k
audio audio-caf.caf   988 -c:a pcm_s16le -f caf

# AMR-NB: the "#!AMR\n" magic, then 20 ms frames of mode 7 (12.2 kbit/s): a header byte and 31 zero bytes each (silence).
python3 - "$out/audio-amr.amr" "$SECS" <<'PY'
import sys
secs = int(sys.argv[2])
open(sys.argv[1], 'wb').write(b'#!AMR\n' + (bytes([0x3c]) + bytes(31)) * (secs * 50))
PY
echo audio-amr.amr
