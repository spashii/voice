# Voice

Speak, and it is typed.

Voice is a free, open source menu bar app for macOS. Press ``Option+` ``, talk, and your words appear live and are typed where your cursor is. Whisper runs on your Mac, so no audio goes to a server. Your own key terms help it spell names right.

With [Blend](https://github.com/spashii/blend), Voice also records your online calls and transcribes both sides live, as you and them. Your agents can read your dictations and a live call transcript over MCP.

## Requirements

A Mac with Apple silicon and macOS 15 or later. For online calls, [Blend](https://github.com/spashii/blend) 0.3 or later.

## Install

1. Download `Voice-VERSION.dmg` from [Releases](../../releases), open it, and drag Voice to Applications. Or install it with Homebrew:

   ```sh
   brew tap spashii/voice https://github.com/spashii/voice
   brew trust spashii/voice
   brew install --cask voice
   ```

2. Open Voice. It is signed with a Developer ID and notarized, so macOS only asks whether to open an app downloaded from the internet. Click **Open**.
3. Voice opens to its setup window. Go through the three steps:
   - **Microphone.** Allow it.
   - **Accessibility.** This is what lets Voice type into other apps.
   - **Speech model.** Voice downloads Whisper once, about 1.6 GB.

Open at login is on from the first launch. Settings turns it off.

## Using Voice

1. Put your cursor in any text field.
2. Press ``Option+` `` and talk. A small pill at the top of the screen shows your words as you say them.
3. Press ``Option+` `` again. The text is typed where your cursor was.

Good to know:

- Add names, products and places to the key terms in Settings. Whisper reads them before every recording and spells them the way you wrote them.
- The menu bar menu lists your recent dictations. Click one to copy it.
- A recording is never thrown away. If Voice quits mid-sentence, the next launch transcribes what it had.
- Settings has the shortcut, the microphone, the language, and an optional step that rewrites the text with a local model in [Ollama](https://ollama.com) before it is typed.

## Online calls with Blend

A microphone hears only your side of a video call. Blend makes a microphone that carries your voice on one channel and the sound of your Mac on the other, and Voice transcribes each channel on its own.

1. In Blend, make a mix from the **Mic and system audio** preset and leave **Split by channel** on.
2. Leave Zoom, Meet, Teams or Discord on your usual microphone. Only Voice reads the mix.
3. Join the call. Voice asks whether to record it, and a shortcut starts and stops call mode at any time.
4. Both sides are transcribed live, you as Me and everyone else as Call. Click the call in the menu to copy the transcript.

The recording stops on its own when the call ends. Audio is kept compressed, about 45 MB an hour.

## Agents

While Voice runs, Claude Code, Codex or any MCP client on your Mac can list and search your dictations, read a call transcript, and follow a call as it happens. The server listens on your Mac only and every request carries a token. [docs/MCP.md](docs/MCP.md) has the setup and the tools.

## Privacy

Everything stays on your Mac. Voice has no account and no cloud, and no analytics. It goes online only to download the speech model once, from Hugging Face, and to check for updates (with [Sparkle](https://sparkle-project.org), sending nothing about you or your Mac).

Recordings, transcripts and the speech model are in `~/Library/Application Support/Voice`. Keep history in Settings deletes dictations and calls older than 30 days, if you want it to.

## Updates

Voice updates itself. On its second launch it asks whether to check for updates automatically, and Settings has a Check for Updates button. Updates are signed, and Voice installs only ones signed with its own key.

## Uninstall

Quit Voice and move it to the Trash. To remove your recordings, transcripts and settings too:

```sh
rm -rf ~/Library/Application\ Support/Voice
defaults delete io.github.spashii.voice
```

With Homebrew, `brew uninstall --zap --cask voice` does both.

## Building

[docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) has the build, the tests and the command line tool. [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) has how a dictation and a call flow through the code.

## License

MIT, see [LICENSE](LICENSE). Voice includes [whisper.cpp](https://github.com/ggml-org/whisper.cpp), [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) and [Sparkle](https://sparkle-project.org). Their licenses are in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
