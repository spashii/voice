#!/bin/zsh
# Builds the release disk image on a Mac: tools/release.sh [--publish]
#
# Output: build/release/Voice-VERSION.dmg and its .sha256, with the same Voice.app in
# build/release/stage. Built in the Release configuration and signed with a Developer ID
# under the hardened runtime with a secure timestamp; both the app and the image are
# notarized and stapled, so Voice opens on any Mac without a Gatekeeper warning, offline too.
# The identity comes from the release keychain Blend's tools/release-identity.sh sets up (one
# Developer ID signs both apps), or from VOICE_SIGN_ID and VOICE_NOTARY_PROFILE in your login
# keychain.
#
# With the update key in place, the image then becomes the newest entry in the update feed
# (site/appcast.xml) and the Homebrew cask (Casks/voice.rb). --publish uploads it as GitHub
# release vVERSION and pushes the feed and the cask; it needs a clean, pushed git checkout
# and gh logged in. Over SSH gh can't read the Mac's keychain, so publish from the machine
# with the checkout instead, as docs/DEVELOPMENT.md describes.
set -euo pipefail
root=${0:A:h:h}
cd $root
version=$(<VERSION)
publish=false
if [[ ${1:-} == --publish ]]; then
  publish=true
  # The release is built from HEAD and tagged there, so HEAD has to be exactly what is on
  # GitHub; these checks fail when GitHub can't be reached, rather than passing.
  [[ -z $(git status --porcelain) ]] || { print -u2 "Commit everything first."; exit 1 }
  git fetch -q origin
  [[ $(git rev-parse HEAD) == $(git rev-parse "@{u}") ]] || { print -u2 "Push HEAD first."; exit 1 }
  gh auth status >/dev/null
  if [[ -n $(gh release list --json tagName -q ".[] | select(.tagName == \"v$version\")") ]]; then
    print -u2 "v$version is already released; raise VERSION."
    exit 1
  fi
fi

identity=${VOICE_SIGN_ID:-}
profile=${VOICE_NOTARY_PROFILE:-}
keychainArgs=()
kc=$HOME/Library/Keychains/blend-release.keychain-db
if [[ -z $identity && -f $kc ]]; then
  security unlock-keychain -p "$(<$HOME/.blend-signing/keychain-password)" $kc
  identity=$(security find-identity -v -p codesigning $kc |
    sed -nE 's/.*"(Developer ID Application: .*)"$/\1/p' | head -1)
  keychainArgs=(--keychain $kc)
  profile=${profile:-blend-notary}
fi
# Release builds run under the hardened runtime, which needs a Developer ID to load the
# embedded frameworks, so there is no ad hoc release; tools/build.sh is for that.
[[ -n $identity && -n $profile ]] || {
  print -u2 "No Developer ID: set up the release keychain, or VOICE_SIGN_ID and VOICE_NOTARY_PROFILE."
  exit 1
}
signFlags=(--timestamp $keychainArgs)

# notarytool exits 0 even when Apple rejects the file, so the status is checked here and a
# rejection prints Apple's reasons.
notarize() {
  local result id
  result=$(xcrun notarytool submit $1 --keychain-profile $profile $keychainArgs --wait \
    --output-format json)
  id=$(print -r -- $result | plutil -extract id raw -o - -)
  if [[ $(print -r -- $result | plutil -extract status raw -o - -) != Accepted ]]; then
    xcrun notarytool log $id --keychain-profile $profile $keychainArgs >&2
    return 1
  fi
  echo "notarized: ${1:t} ($id)"
}

# The Debug build in build/app is left alone, so a Voice running from it keeps running.
out=$root/build/release
rm -rf $out
mkdir -p $out
(cd app && xcodegen generate --quiet)
xcodebuild -project app/Voice.xcodeproj -scheme Voice -configuration Release \
  -destination "platform=macOS,arch=arm64" -derivedDataPath $out/xcode -quiet \
  MARKETING_VERSION=$version CURRENT_PROJECT_VERSION=$version CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$identity" OTHER_CODE_SIGN_FLAGS="$signFlags" build
app=$out/xcode/Build/Products/Release/Voice.app
# voice-cli ships inside the app, so `voice-cli retry-report` and the rest run against the
# installed version: Contents/Helpers/voice-cli, loading the app's own whisper framework.
(cd Core && swift build -c release --product voice-cli)
mkdir -p $app/Contents/Helpers
cp Core/.build/release/voice-cli $app/Contents/Helpers/voice-cli
install_name_tool -add_rpath @executable_path/../Frameworks -delete_rpath @loader_path \
  $app/Contents/Helpers/voice-cli
for rpath in $(otool -l $app/Contents/Helpers/voice-cli | awk '/LC_RPATH/ {getline; getline; print $2}'); do
  [[ $rpath == /Applications/Xcode* ]] && install_name_tool -delete_rpath $rpath $app/Contents/Helpers/voice-cli
done
# Notarization needs every piece of code signed with the Developer ID, the hardened runtime
# and a timestamp, and Xcode signs the frameworks it embeds but not the helpers inside
# Sparkle's. So it is signed inside out: Sparkle's helpers in the order its documentation
# gives for an app that isn't sandboxed, then each framework, then the app, whose signature
# covers the frameworks'.
sign() {
  codesign --force --sign "$identity" --options runtime --preserve-metadata=entitlements \
    $signFlags $1
}
for framework in $app/Contents/Frameworks/*(N); do
  if [[ ${framework:t} == Sparkle.framework ]]; then
    helpers=$framework/Versions/B
    for code in $helpers/XPCServices/Installer.xpc $helpers/XPCServices/Downloader.xpc \
      $helpers/Autoupdate $helpers/Updater.app; do
      sign $code
    done
  fi
  sign $framework
done
sign $app/Contents/Helpers/voice-cli
sign $app
codesign --verify --deep --strict $app

stage=$out/stage
mkdir -p $stage
ditto $app $stage/Voice.app
# The app gets its own ticket, so it opens without a network check once copied out of the
# image.
ditto -c -k --keepParent $stage/Voice.app $out/Voice.zip
notarize $out/Voice.zip
xcrun stapler staple $stage/Voice.app
rm $out/Voice.zip
ln -s /Applications $stage/Applications
dmg=$out/Voice-$version.dmg
hdiutil create -quiet -volname "Voice $version" -srcfolder $stage -fs HFS+ -format UDZO -ov $dmg
codesign --sign "$identity" $signFlags $dmg
notarize $dmg
xcrun stapler staple $dmg
spctl --assess --type execute -v $stage/Voice.app
spctl --assess --type open --context context:primary-signature -v $dmg
(cd $out && shasum -a 256 ${dmg:t} | tee ${dmg:t}.sha256)

# The notarized image becomes the newest entry in the update feed and the Homebrew cask.
# Both are files in the repo, published by committing them after the GitHub release.
sparkle=${VOICE_SPARKLE_DIR:-$HOME/.blend-signing/sparkle-2.10.1}
sparkleKey=${VOICE_SPARKLE_KEY:-$HOME/.blend-signing/sparkle-private-key}
releases=${VOICE_RELEASES_URL:-https://github.com/spashii/voice/releases/download}
if [[ -f $sparkleKey ]]; then
  signature=$($sparkle/bin/sign_update --ed-key-file $sparkleKey $dmg)
  item="    <item>
      <title>Voice $version</title>
      <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
      <sparkle:version>$version</sparkle:version>
      <sparkle:shortVersionString>$version</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
      <enclosure url=\"$releases/v$version/${dmg:t}\" $signature type=\"application/octet-stream\"/>
    </item>"
  ITEM=$item VERSION=$version perl -0pi -e '
    s{\s*<item>(?:(?!</item>).)*<sparkle:version>\Q$ENV{VERSION}\E</sparkle:version>.*?</item>}{}s;
    s{(<!-- tools/release.sh adds each release below this line. -->)}{$1\n$ENV{ITEM}}' site/appcast.xml
  sha=$(cut -d' ' -f1 $dmg.sha256)
  sed -i '' -e "s/^  version \".*\"/  version \"$version\"/" -e "s/^  sha256 \".*\"/  sha256 \"$sha\"/" \
    Casks/voice.rb
else
  print -u2 "No update key at $sparkleKey: site/appcast.xml and Casks/voice.rb are unchanged."
fi
if $publish; then
  [[ -f $sparkleKey ]] || { print -u2 "Not published: a release needs the update key."; exit 1 }
  # The image goes up before the feed that offers it.
  gh release create v$version $dmg $dmg.sha256 --target $(git rev-parse HEAD) \
    --title "Voice $version" --generate-notes
  git commit -q -m "Voice $version appcast and cask" site/appcast.xml Casks/voice.rb
  git push -q
  echo "Published v$version."
elif [[ -f $sparkleKey ]]; then
  echo "Updated site/appcast.xml and Casks/voice.rb; publish them after the GitHub release."
fi
echo "app: $stage/Voice.app"
echo "dmg: $dmg"
