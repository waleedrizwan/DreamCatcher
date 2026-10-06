#!/usr/bin/env bash
# Build an unsigned DreamCatcher.ipa for sideloading (AltStore, SideStore, Sideloadly).
# Those tools re-sign it with the installer's own Apple ID.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/build}"
mkdir -p "${OUT:?}"
rm -rf "${OUT:?}/Payload" "${OUT:?}/DreamCatcher.xcarchive" "${OUT:?}/DreamCatcher.ipa"
mkdir -p "$OUT/Payload"

xcodebuild -project "$ROOT/ios/DreamCatcher.xcodeproj" -scheme DreamCatcher \
  -configuration Release -destination 'generic/platform=iOS' \
  -archivePath "$OUT/DreamCatcher.xcarchive" archive \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" -quiet

cp -R "$OUT/DreamCatcher.xcarchive/Products/Applications/DreamCatcher.app" "$OUT/Payload/"
(cd "$OUT" && zip -qry DreamCatcher.ipa Payload)
echo "$OUT/DreamCatcher.ipa"
