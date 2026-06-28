#!/bin/bash
# One-command release: bump version → build → notarize → DMG → GitHub release → cask update.
#   ./tools/release.sh 1.1.0
# Requires: gh (authenticated), push access to rescenedev/anf and
# rescenedev/homebrew-anf, a "Developer ID Application" cert in the keychain,
# and a notarytool credential profile named "anf-notary" (set up once with:
#   xcrun notarytool store-credentials anf-notary \
#       --key AuthKey_XXXX.p8 --key-id XXXX --issuer XXXX-...).
set -euo pipefail
cd "$(dirname "$0")/.."

NOTARY_PROFILE="anf-notary"

VERSION="${1:?사용법: ./tools/release.sh <version>  (예: 1.1.0)}"
TAG="v$VERSION"

if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "✗ 커밋되지 않은 변경이 있습니다. 먼저 커밋하세요." >&2
    exit 1
fi

# Preflight: fail early (before bumping version / building) if signing or
# notarization isn't set up, so a release never ships unsigned by accident.
if ! security find-identity -p codesigning -v 2>/dev/null | grep -q "Developer ID Application"; then
    echo "✗ 'Developer ID Application' 인증서가 키체인에 없습니다." >&2
    echo "  Xcode → Settings → Accounts → Manage Certificates → + → Developer ID Application" >&2
    exit 1
fi
if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    echo "✗ notarytool 자격증명 프로파일 '$NOTARY_PROFILE' 가 없습니다." >&2
    echo "  xcrun notarytool store-credentials $NOTARY_PROFILE --key AuthKey_XXXX.p8 --key-id XXXX --issuer XXXX-..." >&2
    exit 1
fi

echo "▸ Info.plist 버전 → $VERSION"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" Resources/Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" Resources/Info.plist

echo "▸ 테스트"
# FileTagsTests writes a real Finder tag via a SYNCHRONOUS DesktopServices/Metadata
# XPC call. In a non-interactive context (the launchd nightly job, or a headless
# agent) the metadata daemon doesn't answer and that call blocks forever — hanging
# the whole release at the test step. Skip just that test here; it's still run by
# an interactive `swift run anfTests` and in CI. (See the nightly hang of 1.5.33.)
ANF_SKIP_TAGS=1 swift run anfTests

echo "▸ 빌드"
./build.sh

echo "▸ 공증 (notarytool submit --wait)"
rm -f anf-notarize.zip
ditto -c -k --keepParent anf.app anf-notarize.zip
xcrun notarytool submit anf-notarize.zip --keychain-profile "$NOTARY_PROFILE" --wait
rm -f anf-notarize.zip
echo "▸ 티켓 스테이플"
xcrun stapler staple anf.app
xcrun stapler validate anf.app
spctl -a -vvv anf.app   # 'accepted, source=Notarized Developer ID' 이어야 정상

echo "▸ DMG 생성 (드래그-투-Applications 레이아웃)"
DMG=anf.dmg
rm -f "$DMG"
STAGE=$(mktemp -d)
cp -R anf.app "$STAGE/anf.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "anf" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
codesign --force --timestamp --sign "Developer ID Application" "$DMG"

echo "▸ DMG 공증 + 스테이플"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl -a -t open --context context:primary-signature -vv "$DMG"   # 'accepted, Notarized Developer ID'
SHA=$(shasum -a 256 "$DMG" | awk '{print $1}')
echo "  sha256: $SHA"

echo "▸ 버전 커밋 + 태그"
git add Resources/Info.plist
git commit -m "release: $TAG"
git tag "$TAG"
git push origin main "$TAG"

echo "▸ GitHub Release $TAG"
gh release create "$TAG" anf.dmg --repo rescenedev/anf \
    --title "anf $TAG" --generate-notes

echo "▸ Homebrew cask 갱신"
TAP_DIR=$(mktemp -d)
git clone -q --depth 1 https://github.com/rescenedev/homebrew-anf "$TAP_DIR"
sed -i '' "s/version \"[^\"]*\"/version \"$VERSION\"/" "$TAP_DIR/Casks/anf.rb"
sed -i '' "s/sha256 \"[^\"]*\"/sha256 \"$SHA\"/" "$TAP_DIR/Casks/anf.rb"
sed -i '' "s#/anf\.zip#/anf.dmg#g" "$TAP_DIR/Casks/anf.rb"   # migrate the asset url to .dmg
git -C "$TAP_DIR" commit -aqm "anf $VERSION"
git -C "$TAP_DIR" push -q
rm -rf "$TAP_DIR" anf.dmg

echo "✓ $TAG 릴리즈 완료 — brew upgrade --cask anf 로 받아집니다"
