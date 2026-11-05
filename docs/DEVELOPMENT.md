# Developing Voice

## Setup

You need a Mac with Apple silicon, macOS 15 or later, Xcode 16 or later, and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

## Build and run

```sh
tools/build.sh
open build/app/Build/Products/Debug/Voice.app
```

This builds `Voice.app` and `voice-cli` (`Core/.build/release/voice-cli`). It signs with the "Blend Dev" identity from [Blend](https://github.com/spashii/blend)'s `tools/dev-identity.sh` when that exists, so macOS keeps the microphone and Accessibility permissions across rebuilds. Without it the build is ad hoc, and macOS asks again after every build.

- `tools/fetch-models.sh` puts the speech models in place ahead of the first run. Voice downloads them itself otherwise.
- `tools/sync.sh HOST` copies the checkout to `~/work/voice` on a Mac over SSH, for editing on one machine and building on another.
- `tools/fixtures.sh` copies OpenSuperWhisper's recordings and transcripts into `fixtures/` (gitignored) for `voice-cli eval`.

## Tests

```sh
cd Core && swift test
```

They cover the store and its index, the MCP server, call source choice and detection, channel handling, rebuild, AAC conversion, the chunkers, recovery, the fix step and the pipeline. Ollama is stubbed. The tests that need Whisper run only when `VOICE_TEST_WHISPER_MODEL` points at a model.

`voice-cli` runs the app's pipeline with no window or sound: `transcribe`, `eval`, `batch` and `live` for speech, `call --file`, `fake-call` and `watch-calls --raw` for calls, and `mcp` for the server. The comment at the top of `Core/Sources/voice-cli/main.swift` lists them all.

## Releases

Semver: raise the patch for fixes and the minor for anything new.

```sh
tools/release.sh
```

It builds the Release configuration, signs it with a Developer ID, notarizes and staples the app and the image, and writes `build/release/Voice-VERSION.dmg` with its `.sha256`. It uses the release keychain that Blend's `tools/release-identity.sh` sets up (the same Developer ID signs both apps), or `VOICE_SIGN_ID` and `VOICE_NOTARY_PROFILE` from your login keychain. There is no ad hoc release: the hardened runtime that notarization needs won't load the embedded Whisper framework without a Developer ID.

Updates go through [Sparkle](https://sparkle-project.org) and must be signed with the EdDSA key whose public half is `SUPublicEDKey` in `app/project.yml`, the same key Blend uses. Keep the private key, base64 encoded, at `~/.blend-signing/sparkle-private-key`, with Sparkle's tools unpacked at `~/.blend-signing/sparkle-2.10.1`, or point `VOICE_SPARKLE_KEY` and `VOICE_SPARKLE_DIR` elsewhere. Losing this key means installed copies can't take updates any more.

With the key in place, the release also becomes the newest entry in the update feed, `site/appcast.xml`, and in the Homebrew cask, `Casks/voice.rb`. To publish one, raise `VERSION`, commit and push, then publish in this order, so no copy of Voice is offered an update that isn't there yet:

1. Upload the image as GitHub release `vVERSION`.
2. Commit and push the feed and the cask.

At the Mac, with a git checkout and `gh` logged in, `tools/release.sh --publish` does all of it.

When you build on the Mac over SSH, `gh` there can't read the Mac's keychain, so publish from the machine that has the checkout:

```sh
tools/sync.sh HOST
ssh HOST 'cd ~/work/voice && zsh -l tools/release.sh'
v=$(<VERSION)
scp HOST:work/voice/build/release/Voice-$v.dmg HOST:work/voice/build/release/Voice-$v.dmg.sha256 .
shasum -a 256 -c Voice-$v.dmg.sha256
gh release create v$v Voice-$v.dmg Voice-$v.dmg.sha256 --target $(git rev-parse HEAD) --title "Voice $v" --generate-notes
scp HOST:work/voice/site/appcast.xml site/ && scp HOST:work/voice/Casks/voice.rb Casks/
git commit -m "Voice $v appcast and cask" site/appcast.xml Casks/voice.rb && git push
```

The website is `site/`, published to GitHub Pages by `.github/workflows/pages.yml` when it changes on main. The feed is served from there, at `https://spashii.github.io/voice/appcast.xml`.
