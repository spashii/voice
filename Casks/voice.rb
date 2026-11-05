cask "voice" do
  version "0.4.0"
  sha256 "b83913c54181fee8a60ad92a231be9cd071b1ec02be806bf6d4040df11a8c049"

  url "https://apps.idea2prod.in/voice/download/#{version}"
  name "Voice"
  desc "Dictation and call transcripts with Whisper running on the Mac"
  homepage "https://spashii.github.io/voice/"

  auto_updates true
  depends_on arch: :arm64
  depends_on macos: :sequoia

  app "Voice.app"

  uninstall quit: "io.github.spashii.voice"

  # Every recording and transcript is in Application Support, so only --zap removes them.
  zap trash: [
    "~/Library/Application Support/Voice",
    "~/Library/Caches/io.github.spashii.voice",
    "~/Library/HTTPStorages/io.github.spashii.voice",
    "~/Library/Preferences/io.github.spashii.voice.plist",
  ]
end
