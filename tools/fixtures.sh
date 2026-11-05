#!/bin/zsh
# Copies OpenSuperWhisper's recordings and its transcripts into fixtures/, as NAME.wav and
# NAME.txt, for voice-cli eval. Reads its database read-only and changes nothing of it.
# fixtures/ is gitignored: these are recordings of your voice.
set -euo pipefail
root=${0:A:h:h}
src=$HOME/Library/Application\ Support/ru.starmel.OpenSuperWhisper
out=$root/fixtures/osw
mkdir -p $out
db="file:$src/recordings.sqlite?mode=ro"
for name in $(sqlite3 $db "select fileName from recordings where status = 'completed' order by timestamp"); do
  [[ -f $src/recordings/$name ]] || continue
  cp $src/recordings/$name $out/$name
  sqlite3 $db "select transcription from recordings where fileName = '$name'" > $out/${name:r}.txt
done
ls $out/*.wav | wc -l
