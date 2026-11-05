# Voice

A Mac app that transcribes your online calls live, with you and the other side kept apart, and lets your agents read along. It does dictation too. Everything runs on your Mac.

There are a lot of dictation apps. I built Voice for three things I couldn't get from them:

- **Online calls, both sides apart.** Zoom, Meet, Teams, Discord and other online calls are transcribed while they happen, you as Me and everyone else as Call. This uses a split mix from [Blend](https://github.com/spashii/blend).
- **Agents that read along.** Claude Code and other agents can follow an online call live, search past ones and read dictations, over MCP.
- **No lost recordings.** I lost recordings in other apps to one wrong key. In Voice no key throws a recording away, and a recording cut off by a crash or a quit is transcribed at the next launch.

Dictation is the base: press ``Option+` `` in any text field, talk, and press it again. Your words show in a pill at the top of the screen as you speak, and the text is pasted when you stop. Speech recognition is Whisper large v3 turbo (whisper.cpp) on your Mac's GPU, with your key terms (names Whisper would get wrong) in its prompt.

## Dictation

- One dictation shortcut, ``Option+` `` by default. It is the only way to stop a dictation: there is no Escape and no timeout.
- Every recording is a WAV written as you speak, so a crash loses at most the last buffer. A recording that is too short or fails to transcribe keeps a history row, and a failed one retries from the menu.
- Live text. Voice cuts the speech at pauses and transcribes each piece while you are still talking, so stopping costs only the last piece.
- Pasting is Cmd+V into the app in front, and then the clipboard is restored to what it held. Without Accessibility access the text stays on the clipboard.
- Key terms: names and words Whisper gets wrong, spelled as they should be. The list starts empty.
- An optional fix step: a model in [Ollama](https://ollama.com) rewrites the text with your prompt before it is pasted. If Ollama isn't running or the step fails, Whisper's text is pasted as it is.
- The menu lists your last five dictations and three online calls. Click one to copy it.

## Requirements

A Mac with Apple silicon and macOS 15 or later. Optional:

- [Blend](https://github.com/spashii/blend) 0.3 or later, for both sides of an online call.
- [Ollama](https://ollama.com), for the fix step. The default model is `qwen3.5:9b`.

## Install

1. Download [`Voice-VERSION.dmg`](https://apps.idea2prod.in/voice/download), open it, and drag Voice to Applications. Or install it with Homebrew:

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
- **Speech model:** Large v3 turbo (recommended) or Large v3 (3.1 GB, for languages turbo does worse). It can't change during an online call.
- **Calls:** the shortcut, Record from (the input an online call records from), and Ask to record calls (on).
- **General:** Open at login, Keep history (forever, or 30 days), the Accessibility step, and Agents can read transcripts, with the address and a button that copies the token.
- **About:** the version, Check for Updates, the automatic switch, and the licenses.

Tips:

- Add your own names to the key terms: people, products and places Whisper hasn't heard of.
- If the chosen microphone isn't connected, the default one records and Voice says so.
- Quitting during a dictation keeps the recording. The next launch transcribes it into the history without pasting, and the menu marks it "Recovered a recording".

## Online calls with Blend

An online call has two sides, and a microphone hears only yours. [Blend](https://github.com/spashii/blend) makes a microphone that carries yours and the sound your Mac plays on separate channels, and Voice transcribes each channel on its own.

1. **Make the mix.** In Blend, make a mix with your microphone and turn on System audio. It starts split by channel: your microphone on the left, system audio on the right.
2. **Leave your call app on its usual microphone.** Only Voice reads the mix. Blend leaves every app that reads a mix out of that mix's system audio, so a call app set to the mix would be missing from the call side. Voice warns if one is.
3. **Start recording.** After a call app has used the microphone for 5 seconds (10 for a browser using the microphone and speakers), Voice shows "Record this call?" with Record and Not now. ``Option+Shift+` `` and the menu's "Record this call" start one too.
4. **Read the transcript.** Each side is cut at its pauses and transcribed while the call goes on, yours as Me and everyone else as Call. Click the call in the menu to copy it.
5. **Stop.** Recording stops 15 seconds after the call app stops using audio, with ``Option+Shift+` ``, from the menu, or when an agent says so. Once the transcript is complete, the WAV becomes an AAC `.m4a`: about 45 MB an hour of stereo instead of 690 MB.

Quitting during an online call closes the WAV, and the next launch rebuilds the transcript from the file.

Voice detects online calls in Zoom, Teams, Slack, Discord, FaceTime, WhatsApp, Signal, Telegram, Webex, Skype and Element, and in browsers (Meet, or any call in a tab). An agent can start a recording for any other app.

Settings, Calls, Record from lists Blend's mixes with the side each channel carries, then the system default and your other inputs. Until you pick one, Voice records a split Blend mix if there is one, and otherwise the default microphone, which hears only your side unless the call plays through speakers. If the chosen input is unplugged, the automatic one records instead.

## Agents

While Voice runs, it serves dictations and call transcripts over MCP at `http://127.0.0.1:7766/mcp`, on this Mac only. Every request carries the token in `~/Library/Application Support/Voice/mcp-token`. To add it to Claude Code:

```sh
claude mcp add --transport http --scope user voice http://127.0.0.1:7766/mcp \
  --header "Authorization: Bearer $(cat ~/Library/Application\ Support/Voice/mcp-token)"
```

An agent can list and search online calls and dictations, read a transcript, follow a live call with `wait_for_transcript`, tag calls, and start and stop a call recording. `voice-cli mcp` serves the same thing when the app isn't running. [docs/MCP.md](docs/MCP.md) has every tool.

## How it works

Voice cuts the audio at pauses with the Silero voice activity model and sends each piece to Whisper with the key terms and the text before it as the prompt. On an online call each channel is cut and transcribed on its own, and the two are merged by time.

Whisper gives every segment a confidence, and Voice stores it. Voice can decode the least sure segments again with beam search, spending at most half the time of the first pass. On seven open English test sets that removed about 7.5% of the errors, a real but small gain.

The code has three parts. VoiceCore (`Core/`) records, transcribes, cleans up, stores and serves, with no UI code. `voice-cli` runs the same code from the command line. The app (`app/`, SwiftUI) is the menu bar, the indicator, Settings and the paste. [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) has the modules and how a dictation and an online call flow through them.

## Rough edges

- Apple silicon and macOS 15 or later only.
- Both sides of an online call need Blend. Without it Voice hears only your microphone.
- The speech model is a 1.6 GB download (3.1 GB for Large v3, for languages turbo does worse).
- Dictation shares Whisper with an online call, so a dictation during one waits behind the call's pieces.
- On a 16 GB Mac, Whisper and a large Ollama model don't fit on the GPU together. Voice frees Whisper before the fix step, and skips the fix step while an online call is using Whisper.
- A mute or a device switch doesn't end a recording: it ends only after 15 seconds with neither input nor output.

## Privacy

Voice records and transcribes on your Mac, and your audio stays there. It has no accounts. It goes online only to download the speech models, once, from Hugging Face, and to check for updates with [Sparkle](https://sparkle-project.org). Update checks and downloads go through apps.idea2prod.in, which counts them by app, version and country and never stores your IP address. Whisper runs on the GPU, and the fix step talks to Ollama on `127.0.0.1`.

The MCP server listens on `127.0.0.1` only and answers nothing without the token. A switch in Settings turns it off.

Voice uses the microphone while you dictate or record an online call. To paste, it puts the text on the clipboard, pastes, and half a second later puts back what was there.

## Where your data lives

Everything is in `~/Library/Application Support/Voice`:

- `recordings/`: each dictation as `<ms>.wav`, 16 kHz mono.
- `calls/`: each online call as `<ms>-<id>.wav` while it records, then `.m4a`.
- `voice.sqlite`: dictations, online calls with their segments and tags, and one full-text index over both.
- `models/`: the speech models.
- `mcp-token`: the MCP token, readable by you only.

Settings are in the app's preferences (`io.github.spashii.voice`). Keep history set to 30 days deletes dictations and online calls older than that, with their audio. It never deletes a call that is still recording or being transcribed.

## Uninstall

Quit Voice and move it to the Trash. To remove your recordings, transcripts and settings too:

```sh
rm -rf ~/Library/Application\ Support/Voice
defaults delete io.github.spashii.voice
```

With Homebrew, `brew uninstall --zap --cask voice` does both.

## License

MIT, see [LICENSE](LICENSE). Voice includes [whisper.cpp](https://github.com/ggml-org/whisper.cpp), [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) and [Sparkle](https://sparkle-project.org). Their licenses are in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
