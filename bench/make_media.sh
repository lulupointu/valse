#!/bin/bash
# Generates shared benchmark media into bench/media (idempotent).
set -euo pipefail
cd "$(dirname "$0")"; mkdir -p media
gen() { # name lavfi-src hue
  [ -f "media/$1.mp4" ] && return
  ffmpeg -loglevel error -y -f lavfi -i "$2" -f lavfi -i "sine=frequency=$4:sample_rate=48000" -t 60 \
    -vf "hue=h=$3,format=yuv420p" -c:v hevc_videotoolbox -b:v 30M -tag:v hvc1 -c:a aac -b:a 128k "media/$1.mp4"
}
gen a "testsrc2=size=3840x2160:rate=30" 0 440
gen b "mandelbrot=size=3840x2160:rate=30" 90 550
gen c "testsrc2=size=3840x2160:rate=30" 180 660
gen d "life=size=3840x2160:rate=30:mold=10:ratio=0.5:death_color=#203040:life_color=#e0a020" 270 330
[ -f media/h264_1080.mp4 ] || ffmpeg -loglevel error -y -f lavfi -i "testsrc2=size=1920x1080:rate=30" -f lavfi -i "sine=frequency=500:sample_rate=48000" -t 60 \
  -c:v h264_videotoolbox -b:v 12M -pix_fmt yuv420p -c:a aac media/h264_1080.mp4
if [ ! -f media/speech_fr.wav ]; then
  say -v "Thomas" -o media/speech_fr.aiff -f speech_fr.txt 2>/dev/null || say -v "Eddy (French (France))" -o media/speech_fr.aiff -f speech_fr.txt
  ffmpeg -loglevel error -y -i media/speech_fr.aiff -ar 16000 -ac 1 media/speech_fr.wav && rm media/speech_fr.aiff
fi
touch media/.done
