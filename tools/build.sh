#!/bin/zsh
# Builds Voice.app and voice-cli on a Mac: tools/build.sh
#
# Signs the app with the "Blend Dev" identity from Blend's tools/dev-identity.sh when it
# exists, so macOS keeps the microphone and Accessibility permissions across rebuilds; ad
# hoc otherwise, which asks for them again after every build.
set -euo pipefail
root=${0:A:h:h}
cd $root
version=$(<VERSION)

identity=-
keychain=
kc=~/Library/Keychains/blend-dev.keychain-db
if [[ -f $kc ]]; then
  security unlock-keychain -p blend-dev $kc
  identity="Blend Dev"
  keychain=$kc
fi

(cd Core && swift build -c release --product voice-cli)
(cd app && xcodegen generate --quiet)
xcodebuild -project app/Voice.xcodeproj -scheme Voice -configuration Debug \
  -destination "platform=macOS,arch=arm64" -derivedDataPath build/app -quiet \
  MARKETING_VERSION=$version CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$identity" \
  ${keychain:+OTHER_CODE_SIGN_FLAGS=--keychain $keychain} build
echo "app: $root/build/app/Build/Products/Debug/Voice.app"
echo "cli: $root/Core/.build/release/voice-cli"
