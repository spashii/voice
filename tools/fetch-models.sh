#!/bin/zsh
# Puts whisper's model and the voice activity model where Voice looks for them.
# OpenSuperWhisper's copy of the whisper model is cloned when it's there: an APFS clone
# takes no space and leaves its file as it was.
set -euo pipefail
models=$HOME/Library/Application\ Support/Voice/models
mkdir -p $models
whisper=$models/ggml-large-v3-turbo.bin
osw=$HOME/Library/Application\ Support/ru.starmel.OpenSuperWhisper/whisper-models/ggml-large-v3-turbo.bin
if [[ ! -f $whisper ]]; then
  if [[ -f $osw ]]; then
    cp -c $osw $whisper
  else
    curl -fL --progress-bar -o $whisper.part \
      https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin
    mv $whisper.part $whisper
  fi
fi
vad=$models/ggml-silero-v5.1.2.bin
if [[ ! -f $vad ]]; then
  curl -fsL -o $vad.part https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin
  mv $vad.part $vad
fi
ls -l $models
