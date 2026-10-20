#!/bin/bash
# (Re)generates the small committed "real-like" media fixtures in app/Tests/UIScripts/fixtures/real/ (needs ffmpeg with
# libx265 + macOS `say`). Everything is synthetic — no personal footage. Re-run only to change them (commit the result).
#   iphone_hlg_portrait.mov  iPhone-style clip: HEVC Main10 (yuv420p10le, B-frames, 1 s GOP), BT.2020 / HLG / limited range,
#                            coded 1920×1080 with a −90° display matrix (displays 1080×1920 portrait), 30 fps, 4 s,
#                            a drawn face (Vision detects it) with handheld shake + sensor noise, a bright window above
#                            SDR white, AAC 44.1 kHz stereo carrying speech, Apple make/model tags
#   speech_en.m4a            English speech (say, en_GB), ~0.9 s pause in the middle, AAC 48 kHz mono
#   music_120bpm.m4a         8 s, 120 BPM: kick on every beat, hi-hat off-beats, two alternating chords, AAC stereo
# Owner footage stays opt-in and uncommitted: MONTAGE_REAL_FOOTAGE="/path/a.MOV|/path/b.MOV" (docs/TESTING.md).
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=app/Tests/UIScripts/fixtures/real
mkdir -p "$OUT"
T="$(mktemp -d -t montage-fixtures)"; trap 'rm -rf "$T"' EXIT
command -v ffmpeg >/dev/null || { echo "ffmpeg missing (brew install ffmpeg)"; exit 1; }

# ---- speech -----------------------------------------------------------------------------------------------------
say -v Daniel -o "$T/speech.aiff" "Hi, this is a short test recording for the video editor. [[slnc 900]] After the pause, I keep talking about colours, captions and waveforms."
ffmpeg -v error -y -i "$T/speech.aiff" -af "aresample=48000" -ac 1 -c:a aac -b:a 64k "$OUT/speech_en.m4a"

# ---- music ------------------------------------------------------------------------------------------------------
# kick = pitch-dropping body (150 → 50 Hz) + beater click, like a real bass drum; quieter hats on the off-beats
KICK='0.75*sin(2*PI*(50*mod(t,0.5)+2.5*(1-exp(-mod(t,0.5)*40))))*exp(-mod(t,0.5)*9)+0.35*(2*random(1)-1)*exp(-mod(t,0.5)*300)'
HAT='0.05*(2*random(0)-1)*exp(-mod(t+0.25,0.5)*90)'
PAD='0.07*if(lt(mod(t,4),2),sin(2*PI*220*t)+sin(2*PI*277.18*t)+sin(2*PI*329.63*t),sin(2*PI*174.61*t)+sin(2*PI*220*t)+sin(2*PI*261.63*t))'
ffmpeg -v error -y -f lavfi -i "aevalsrc='$KICK+$HAT+$PAD|$KICK+0.8*$HAT+$PAD':s=44100:d=8" -c:a aac -b:a 96k "$OUT/music_120bpm.m4a"

# ---- iPhone-like portrait HLG clip --------------------------------------------------------------------------------
E() { echo "lte(pow((X-$1)/$2,2)+pow((Y-$3)/$4,2),1)"; }          # ellipse cx rx cy ry
FACE="$(E 540 215 920 285)"; HAIR="$(E 540 250 790 240)"; BODY="$(E 540 520 1950 620)"
EARS="max($(E 322 30 940 60),$(E 758 30 940 60))"
NECK="between(X,470,610)*between(Y,1100,1400)"
SOCK="max($(E 455 70 890 42),$(E 625 70 890 42))"
EYEL="$(E 455 44 892 18)"; EYER="$(E 625 44 892 18)"; IRL="$(E 455 16 892 16)"; IRR="$(E 625 16 892 16)"
PUP="max($(E 455 7 892 7),$(E 625 7 892 7))"
BROW="max($(E 452 56 842 10),$(E 628 56 842 10))"; NOSE="$(E 540 24 990 44)"; NOSTR="max($(E 522 9 1028 6),$(E 558 9 1028 6))"
LIPU="$(E 540 70 1086 13)"; LIPL="$(E 540 62 1104 16)"; LIPGAP="between(Y,1095,1098)*between(X,478,602)"
WINDOW="between(X,60,420)*between(Y,120,760)"
SHADE="(1-0.32*pow((X-540)/215,2)-0.14*pow((Y-900)/285,2))"
# layers top → bottom; component values per argument: window wall hair body neck skin eyewhite iris brow lips pupil
layer() {
  local win=$1 wall=$2 hair=$3 body=$4 neck=$5 skin=$6 white=$7 iris=$8 brow=$9 lips=${10} pupil=${11}
  echo "if($PUP,$pupil,if($IRL+$IRR,$iris,if($EYEL+$EYER,$white,if($BROW,$brow,if($LIPGAP,$brow,if($LIPU+$LIPL,$lips*$SHADE,if($NOSTR,$skin*0.55,if($NOSE,$skin*0.9*$SHADE,if($SOCK,$skin*0.84*$SHADE,if($FACE,$skin*$SHADE,if($EARS,$skin*0.8,if($HAIR*lt(Y,1000),$hair,if($NECK,$neck,if($BODY,$body,if($WINDOW,$win,$wall*(1-Y/5000))))))))))))))))"
}
R="$(layer 250 166 58 38 170 214 232 70 50 168 20)"
G="$(layer 250 156 40 58 124 160 228 48 34 92 16)"
B="$(layer 244 142 30 108 100 132 222 34 26 92 14)"
ffmpeg -v error -y -f lavfi -i "color=c=black:s=1080x1920,format=rgb24" -frames:v 1 \
  -vf "geq=r='$R':g='$G':b='$B',gblur=sigma=3" "$T/still.png"
if [[ -n "${MONTAGE_FIXTURE_STILL:-}" ]]; then cp "$T/still.png" "$MONTAGE_FIXTURE_STILL"; fi
# SDR drawing → real HLG signal: BT.709 display gamma → linear → BT.2020 primaries → scene light with SDR white at
# HLG 75 % (BT.2408, E = 0.265) → HLG OETF. The window (near-white) is 3× SDR white: a highlight above SDR, as in iPhone HLG.
L() { echo "pow($1(X,Y)/255,2.4)"; }
BOOST="if(gte(r(X,Y)+g(X,Y)+b(X,Y),735),3,1)"
OETF() { echo "255*if(lte($1,1/12),sqrt(3*$1),0.17883277*log(12*$1-0.28466892)+0.55991073)"; }
ER="(0.265*$BOOST*(0.6274*$(L r)+0.3293*$(L g)+0.0433*$(L b)))"
EG="(0.265*$BOOST*(0.0691*$(L r)+0.9195*$(L g)+0.0114*$(L b)))"
EB="(0.265*$BOOST*(0.0164*$(L r)+0.0880*$(L g)+0.8956*$(L b)))"
ffmpeg -v error -y -i "$T/still.png" -vf "format=rgb24,geq=r='$(OETF "$ER")':g='$(OETF "$EG")':b='$(OETF "$EB")'" "$T/still_hlg.png"
mv "$T/still_hlg.png" "$T/still.png"
[[ -n "${MONTAGE_FIXTURE_STILL:-}" ]] && exit 0
# speech + faint room tone, iPhone audio format
ffmpeg -v error -y -i "$OUT/speech_en.m4a" -f lavfi -i "anoisesrc=color=pink:amplitude=0.004:r=44100:d=4" \
  -filter_complex "[0:a]aresample=44100,apad,atrim=0:4,pan=stereo|c0=c0|c1=c0[s];[s][1:a]amix=inputs=2:normalize=0[a]" -map "[a]" "$T/audio.wav"
# frames: upright portrait content with handheld shake, sensor noise; coded rotated 90° CCW like the iPhone sensor
ffmpeg -v error -y -loop 1 -framerate 30 -i "$T/still.png" -i "$T/audio.wav" -t 4 \
  -vf "crop=w=1040:h=1848:x='20+14*sin(2.1*t)':y='36+20*sin(1.7*t+1)',scale=1080:1920,setsar=1,noise=alls=7:allf=t,transpose=cclock,format=yuv420p10le" \
  -c:v libx265 -preset medium -crf 30 -profile:v main10 -tag:v hvc1 \
  -x265-params "log-level=error:keyint=30:min-keyint=30:bframes=3:colorprim=bt2020:transfer=arib-std-b67:colormatrix=bt2020nc:range=limited" \
  -color_primaries bt2020 -color_trc arib-std-b67 -colorspace bt2020nc -color_range tv \
  -c:a aac -b:a 96k -ar 44100 -ac 2 "$T/coded.mov"
# −90° display matrix (= rotate 90° clockwise on display, as iPhone portrait recordings) + Apple tags, no re-encode
ffmpeg -v error -y -display_rotation:v:0 -90 -i "$T/coded.mov" -c copy -map 0 \
  -metadata "com.apple.quicktime.make=Apple" -metadata "com.apple.quicktime.model=iPhone 15 Pro" \
  -metadata "creation_time=2026-10-01T12:00:00Z" -movflags use_metadata_tags "$OUT/iphone_hlg_portrait.mov"
# ffmpeg writes the rotation without its translation; iPhone files carry tx = coded height (matrix 0 1 −1 0 1080 0)
python3 -I - "$OUT/iphone_hlg_portrait.mov" <<'PY'
import struct, sys
p = sys.argv[1]; b = bytearray(open(p, "rb").read()); i = 0; n = 0
while (i := b.find(b"tkhd", i + 1)) > 0:
    s = i - 4; v = b[s + 8]
    m = s + (48 if v == 0 else 60)
    w, h = struct.unpack(">II", b[m + 36:m + 44])
    a, bb, u, c = struct.unpack(">iiii", b[m:m + 16])
    if w and h and bb == 65536 and c == -65536:
        b[m + 24:m + 28] = struct.pack(">i", (h >> 16) << 16); n += 1
open(p, "wb").write(b)
print(f"patched {n} video track matrix")
PY
ls -l "$OUT"
ffprobe -v error -show_entries stream=codec_name,profile,width,height,pix_fmt,color_transfer,color_primaries,r_frame_rate,sample_rate,channels:stream_side_data=rotation -of compact "$OUT/iphone_hlg_portrait.mov"
