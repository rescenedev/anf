#!/bin/bash
# Nightly build (issue #-batching policy): at midnight, if main has
# merged-but-unreleased source changes, cut ONE notarized release that bundles
# every issue-fix PR merged during the day — instead of releasing per merge.
#
# Installed as a launchd LaunchAgent by tools/install-nightly.sh. Signing +
# notarization need this Mac's keychain (Developer ID cert + the `anf-notary`
# profile), so this can only run locally, never in the cloud.
set -euo pipefail
cd "$(dirname "$0")/.."

# launchd hands jobs a bare PATH — make sure git/gh/swift/xcrun resolve.
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

LOG_DIR="$HOME/Library/Logs/anf-nightly"
mkdir -p "$LOG_DIR"
exec >>"$LOG_DIR/nightly-$(date +%Y%m%d).log" 2>&1
echo "===== nightly run $(date) ====="

# Sync main to exactly origin/main. Hard-reset (not pull) so a PRIOR failed run
# can't block this one: release.sh bumps Info.plist BEFORE running tests, so a
# red test leaves that bump uncommitted — and the next run's clean-tree check
# would then abort. Reset discards that leftover. Untracked scratch
# (black-board.md / .gstack) is gitignored, so it survives.
git fetch origin --tags --quiet
git checkout main --quiet
git reset --hard origin/main --quiet

LATEST_TAG=$(git tag --sort=-v:refname | grep '^v[0-9]' | head -1)
echo "latest tag: $LATEST_TAG"

COMMITS=$(git rev-list "${LATEST_TAG}..HEAD" --count)
echo "commits since tag: $COMMITS"
if [ "$COMMITS" -eq 0 ]; then
    echo "nothing merged since the last release — skipping."
    exit 0
fi

# Only ship when there's an actual user-facing change. Tooling/test/docs-only
# days (tools/, Tests/, *.md, .gitignore) don't warrant a release + cask bump.
CHANGED=$(git diff --name-only "${LATEST_TAG}..HEAD")
if ! echo "$CHANGED" | grep -qE '^(Sources|Resources)/'; then
    echo "no Sources/ or Resources/ changes since $LATEST_TAG — skipping nightly."
    echo "changed paths were:"; echo "$CHANGED" | sed 's/^/  /'
    exit 0
fi

# Next patch version (vX.Y.Z -> X.Y.(Z+1)).
VER="${LATEST_TAG#v}"
IFS=. read -r MAJ MIN PAT <<<"$VER"
NEXT="$MAJ.$MIN.$((PAT + 1))"
echo "releasing $NEXT — bundles $COMMITS commit(s) since $LATEST_TAG"

# release.sh runs tests, builds, Developer-ID signs, notarizes, makes the DMG,
# tags, pushes, and updates the Homebrew cask. It aborts on a red test run.
./tools/release.sh "$NEXT"
echo "===== nightly done $(date): shipped v$NEXT ====="
