# Voice

Dictation and call transcripts on your Mac, kept on your Mac.

Voice is a free, open source menu bar app for macOS. Press a shortcut, speak, press it again, and the text is pasted where you were typing. When you join a call, Voice offers to record it and writes down both sides as they speak. Speech recognition is Whisper (whisper.cpp) on your Mac's GPU, so no audio goes to a server. Your agents can read dictations and the call in progress over MCP.

- **Dictate into any app.** ``Option+` `` starts and stops. The words appear in a small pill at the top of the screen while you speak, and the whole text is pasted when you stop.
- **Names spelled right.** A list of key terms goes to Whisper with every recording. A local model in Ollama can also fix the text with a prompt you write.
- **Nothing is lost.** Every recording is kept. One cut off by a crash or a quit is found at the next launch and transcribed.
- **A transcript of the call as it happens.** With a [Blend](https://github.com/spashii/blend) mix, Voice transcribes each side live, as Me and Call, and keeps the audio compressed.
- **Agents that read it.** Claude Code and other agents read dictations and live call transcripts over MCP, with a token.

## Features

- One shortcut, ``Option+` `` by default. It is the only way to stop a recording: there is no Escape and no timeout, so no stray key throws a recording away.
- Live text. Voice cuts the speech at pauses and transcribes each piece while you are still talking, so stopping costs only the last piece.
- Pasting is Cmd+V into the app in front, and then the clipboard is restored to what it held. Without Accessibility access the text stays on the clipboard.
- Key terms: names and words Whisper gets wrong, spelled as they should be. They open Whisper's prompt, followed by the text just before each piece. The list starts empty.
- An optional fix step: a model in Ollama rewrites the text with your prompt before it is pasted. If Ollama isn't running or the step fails, Whisper's text is pasted as it is.
- Every recording is a WAV written as you speak, so a crash loses at most the last buffer. A recording that is too short or fails to transcribe keeps a history row, and a failed one retries from the menu.
- Calls: Voice asks "Record this call?" when a call app uses the microphone, transcribes each side live and replaces the call's WAV with AAC once the transcript is complete.
- The menu lists your last five dictations and three calls. Click one to copy it.
- Agents search and read all of it over MCP, and can start and stop a call recording.

## Requirements

A Mac with Apple silicon and macOS 15 or later. Optional:

- [Ollama](https://ollama.com), for the fix step. The default model is `qwen3.5:9b`.
- [Blend](https://github.com/spashii/blend) 0.3 or later, for both sides of a call.
- [Tailscale](https://tailscale.com), to reach the MCP server from your other devices.

## Install

1. Download `Voice-VERSION.dmg` from [Releases](../../releases), open it, and drag Voice to Applications. Or install it with Homebrew:

   ```sh
   brew tap spashii/voice https://github.com/spashii/voice
   brew trust spashii/voice
   brew install --cask voice
   ```

2. Open Voice. It is signed with a Developer ID and notarized, so macOS only asks whether to open an app downloaded from the internet. Click **Open**.
3. Voice opens a Set Up Voice window with three steps and closes it when they are done:
   - **Microphone.** Allow it.
   - **Accessibility.** This lets Voice paste into other apps.
   - **Speech model.** Voice downloads Whisper large v3 turbo (1.6 GB) and the Silero voice activity model from Hugging Face. If OpenSuperWhisper has the same model, Voice clones its copy, which takes no space.

Then press ``Option+` `` in any text field, speak, and press it again. Open at login is on from the first launch; Settings turns it off.

Voice updates itself: on its second launch it asks whether to check for updates automatically, and Settings has a Check for Updates button. Updates are signed, and Voice installs only ones signed with its own key. To build Voice from source, see [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).

## Settings

Settings is in the menu bar menu.

- **Dictate:** the shortcut, the microphone (the system default, or one you pick), and the language (English, a language you pick, or detect).
- **Fix the text:** a switch (off), the Ollama model, the prompt, and the key terms. The key terms go to Whisper whether or not the switch is on.
- **Speech model:** Large v3 turbo (recommended) or Large v3 (3.1 GB, for languages turbo does worse). It can't change during a call.
- **Calls:** Ask to record calls (on), and the source Voice will record, which it shows and you don't set.
- **General:** Open at login, Keep history (forever, or 30 days), the Accessibility step, and Agents can read transcripts, with both addresses and a button that copies the token.
- **About:** the version, Check for Updates, the automatic switch, and the licenses.

Good to know:

- Add your own names to the key terms: people, products and places Whisper hasn't heard of.
- If the chosen microphone isn't connected, the default one records and Voice says so.
- On a 16 GB Mac, Whisper and a large model don't fit on the GPU together. Voice frees Whisper before the fix step and asks Ollama to keep its model for two minutes only. The fix step is skipped while a call is using Whisper.
- Quitting during a dictation keeps the recording. The next launch transcribes it into the history without pasting, and the menu marks it "Recovered a recording".

## Calls with Blend

A call has two sides, and a microphone hears only yours. [Blend](https://github.com/spashii/blend) makes a microphone that carries yours and the sound your Mac plays, on separate channels, and Voice transcribes each channel on its own.

1. **Make the mix.** In Blend, make a mix from the **Mic and system audio** preset and leave **Split by channel** on. Your microphone is on the left and system audio on the right.
2. **Leave your call app on its usual microphone.** Only Voice reads the mix. Blend leaves every app that reads a mix out of that mix's system audio, so a call app set to the mix would be missing from the call side. Voice warns if one is.
3. **Join a call.** After a call app has used the microphone for 5 seconds (10 for a browser using the microphone and speakers), Voice shows "Record this call?" with Record and Not now. The menu has "Record this call" too.
4. **Read the transcript.** Each side is cut at its pauses and transcribed while the call goes on, yours as Me and everyone else as Call. Click the call in the menu to copy it.
5. **Stop.** Recording stops 15 seconds after the call app stops using audio, from the menu, or when an agent says so. When the transcript is complete, the WAV becomes an AAC `.m4a`: about 45 MB an hour of stereo instead of 690 MB.

Good to know:

- Without Blend, Voice records the default microphone, which hears only your side unless the call plays through speakers. Voice records the first of these that exists: a split Blend mix, then a Blend mix with system audio as one channel (no Me and Call), then the default microphone. Settings shows which.
- A mute or a device switch doesn't end a call: it ends only after 15 seconds with neither input nor output.
- Quitting during a call closes the WAV. The next launch rebuilds the transcript from the file.
- Dictation works during a call, but it shares Whisper with the call, so a dictation waits behind the call's pieces.
- Voice detects calls in Zoom, Teams, Slack, Discord, FaceTime, WhatsApp, Signal, Telegram, Webex, Skype and Element, and in browsers. An agent can start a recording for any other app.

## Agents

While Voice runs, it serves dictations and call transcripts over MCP at `http://127.0.0.1:7766/mcp`. Every request carries the token in `~/Library/Application Support/Voice/mcp-token`. An agent can list and search calls and dictations, read a transcript, follow a live call with `wait_for_transcript`, tag calls, and start and stop a call recording. `voice-cli mcp` serves the same thing when the app isn't running.

To reach it from your other devices, put it on your tailnet with Tailscale Serve, a step you run yourself. [docs/MCP.md](docs/MCP.md) has the addresses, the token, the Tailscale commands and every tool.

## Privacy

Voice works entirely on your Mac. It has no analytics and no accounts. It goes online only to download the speech models, once, from Hugging Face, and to check for updates (with [Sparkle](https://sparkle-project.org), sending nothing about you or your Mac). Whisper runs on the GPU, and the fix step talks to Ollama on `127.0.0.1`.

The MCP server listens on `127.0.0.1` only and answers nothing without the token. It reaches other devices only if you put it on your tailnet with Tailscale Serve, and then only inside your tailnet. A switch in Settings turns it off.

Voice uses the microphone while you dictate or record a call. To paste, it puts the text on the clipboard, pastes, and half a second later puts back what was there.

## Where your data lives

Everything is in `~/Library/Application Support/Voice`:

- `recordings/`: each dictation as `<ms>.wav`, 16 kHz mono.
- `calls/`: each call as `<ms>-<id>.wav` while it records, then `.m4a`.
- `voice.sqlite`: dictations, calls with their segments and tags, and one full-text index over both.
- `models/`: the speech models.
- `mcp-token`: the MCP token, readable by you only.

Settings are in the app's preferences (`io.github.spashii.voice`). Keep history set to 30 days deletes dictations and calls older than that, with their audio. It never deletes a call that is still recording or being transcribed. Nothing is backed up anywhere by Voice, so include this folder in your own backups.

## Uninstall

Quit Voice and move it to the Trash. To remove your recordings, transcripts and settings too:

```sh
rm -rf ~/Library/Application\ Support/Voice
defaults delete io.github.spashii.voice
```

With Homebrew, `brew uninstall --zap --cask voice` does both. If you set up Tailscale Serve for the MCP server, turn it off as [docs/MCP.md](docs/MCP.md) shows.

## How it works

Voice has three parts. VoiceCore (`Core/`) records, transcribes, cleans up, stores and serves, with no UI code. `voice-cli` runs the same code from the command line. The app (`app/`, SwiftUI) is the menu bar, the indicator, Settings and the paste. [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) has the modules, how a dictation and a call flow through them, and the rules the code keeps.

## License

MIT, see [LICENSE](LICENSE). Voice includes [whisper.cpp](https://github.com/ggml-org/whisper.cpp), [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) and [Sparkle](https://sparkle-project.org). Their licenses are in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
