#!/bin/zsh
# Builds the Quick cut bench corpus (raw 16 kHz mono f32) into <out>/raw. Needs macOS `say` + ffmpeg.
# usage: docs/quickcut/gen_corpus.sh <out dir>   then: swiftc -O docs/quickcut/bench.swift -o <out>/bench && <out>/bench <out>
set -e
out=${1:?out dir}; repo=${0:A:h:h:h}
mkdir -p $out/tts $out/raw
i=0
while IFS='|' read -r v t; do
  i=$((i+1)); say -v "$v" -o $out/tts/s$i.aiff "$t"
  ffmpeg -v error -y -i $out/tts/s$i.aiff -ar 16000 -ac 1 -f f32le $out/raw/s_$i.f32
done <<'EOF'
Samantha|Okay so today I want to show you how I edit my videos really fast.
Samantha|First thing, you import everything into the timeline.
Samantha|Then, um, you select all the clips, and you hit the quick cut button.
Samantha|It removes all the dead air between your sentences.
Samantha|Honestly this saves me hours every single week.
Daniel|Right, let's talk about the lighting setup for a second.
Daniel|I use a single soft box, positioned slightly above my eye line.
Daniel|The background light is just a cheap LED strip.
Daniel|Nothing fancy, but it does the job perfectly well.
Thomas|Bonjour à tous, et bienvenue dans cette nouvelle vidéo.
Thomas|Aujourd'hui on va parler de montage, et surtout de rapidité.
Thomas|Le plus long, c'est souvent de couper les silences.
Flo|Alors, euh, je vais vous montrer une astuce toute simple.
Flo|Vous sélectionnez vos clips, puis vous réglez la durée minimale.
Flo|Et voilà, le tour est joué, c'est vraiment magique.
EOF
music=$(ls $repo/app/Sources/MontageEngine/Resources/ContentLibrary/**/*.m4a 2>/dev/null | head -1)
[[ -n $music ]] || music=$(ls $repo/build/Montage.app/Contents/Resources/Content/music/*.m4a | head -1)
ffmpeg -v error -y -i "$music" -t 120 -ar 16000 -ac 1 -f f32le $out/raw/music.f32
for f in app/Tests/UIScripts/fixtures/real/speech_en.m4a bench/media/speech_fr.wav bench/media/a.mp4; do
  ffmpeg -v error -y -i $repo/$f -ar 16000 -ac 1 -f f32le $out/raw/real_${${f:t}%.*}.f32
done
