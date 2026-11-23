#!/bin/zsh
# Builds Traces for iPhone/iPad and Mac through SelfStore, publishes the Mac app as a GitHub release
# and points the website (docs/, GitHub Pages) at it.
#
#   scripts/deploy.sh ["Release notes"]
#
# Steps:
#   0. Make sure the generated pieces exist (engine bundle, Rust XCFramework) and regenerate the Xcode project.
#   1. Build Traces-iOS in SelfStore and export it into the repo (selfstore/Traces-iOS.ipa + selfstore.yml),
#      so anyone can add this repo to their SelfStore and install the app without building it.
#   2. Build Traces-Mac in SelfStore (archive, Developer ID signing, notarization, .dmg + .zip).
#   3. Release Traces.dmg / Traces.zip on GitHub, write docs/latest.json, push, and turn on Pages.
#
# The builds run through the SelfStore already running on this Mac (http://localhost:8765). Set up
# signing in SelfStore ▸ Settings first. Needs `gh auth login`.
#
# Env: SELFSTORE_URL (default http://localhost:8765), FULL=1 to rebuild the engine and Rust core even if
# they exist, SKIP_IOS=1 to skip the iPhone build, SKIP_MAC=1 to only do the iPhone build,
# SITE_ONLY=1 to just push docs/ (no builds), ALLOW_UNNOTARIZED=1 to publish an un-notarized Mac build,
# DRAFT=1 to create a draft release, DRY_RUN=1 to build and download only (no commits, pushes or releases).
set -euo pipefail
cd "${0:A:h}/.."
ROOT=$PWD
API=${SELFSTORE_URL:-http://localhost:8765}/api
NOTES=${1:-}
APP=Traces
XCODEPROJ=$ROOT/app/Traces.xcodeproj

say() { print -P "%F{cyan}==>%f $*"; }
die() { print -P "%F{red}error:%f $*" >&2; exit 1; }
json() { python3 -c "import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1]))" "$1"; }

if [[ ${DRY_RUN:-0} != 1 ]]; then
  command -v gh >/dev/null || die "Install the GitHub CLI: brew install gh"
  gh auth status >/dev/null 2>&1 || die "Run gh auth login first"
  REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner) || die "No GitHub repo for this checkout (gh repo create)"
fi

enable_pages() {
  if ! gh api "repos/$REPO/pages" >/dev/null 2>&1; then
    say "Turning on GitHub Pages (main /docs)"
    gh api -X POST "repos/$REPO/pages" -f 'source[branch]=main' -f 'source[path]=/docs' >/dev/null \
      || print -P "%F{yellow}warning:%f couldn't enable Pages. Turn it on in the repo's Settings ▸ Pages (branch main, folder /docs)."
  fi
  PAGES=$(gh api "repos/$REPO/pages" -q .html_url 2>/dev/null || echo "https://${REPO%%/*}.github.io/${REPO#*/}/")
  say "Website: $PAGES (updates in a minute or two)"
}

# Website only: commit and push docs/, make sure Pages is on.
if [[ ${SITE_ONLY:-0} == 1 ]]; then
  [[ ${DRY_RUN:-0} == 1 ]] && die "SITE_ONLY and DRY_RUN together do nothing"
  git add docs
  git diff --cached --quiet -- docs || git commit -q -m "Website: update" -- docs
  git push -q origin HEAD
  enable_pages
  exit 0
fi

curl -sf "$API/info" >/dev/null || die "SelfStore isn't running at $API. Open SelfStore on this Mac."

if [[ ${DRY_RUN:-0} != 1 && -n $(git status --porcelain -- . ':!docs/latest.json' ':!selfstore' ':!selfstore.yml') ]]; then
  print -P "%F{yellow}warning:%f the working tree has uncommitted changes; they'll be in the build but not in the tagged commit."
  if [[ -t 0 ]]; then read -q "?Continue? [y/N] " || { echo; exit 1; }; echo; fi
fi

# 0. Generated pieces (gitignored): the tscircuit engine bundle and the Rust core.
if [[ ${FULL:-0} == 1 || ! -f app/Shared/Resources/engine.js ]]; then say "Bundling the engine"; make engine; fi
if [[ ${FULL:-0} == 1 || ! -d app/TraceworksCore.xcframework || ! -f app/Shared/Generated/traceworks_core.swift ]]; then
  say "Building the Rust core"; make core
fi
say "Generating the Xcode project"; make -s project >/dev/null

# Finds (or registers) the SelfStore project for a scheme of this checkout and prints its id.
project_id() {  # scheme platform
  local id
  id=$(curl -sf "$API/projects" | python3 -c '
import json,sys
d=json.load(sys.stdin); scheme=sys.argv[1]
print(next((p["id"] for p in d if p.get("name")==scheme and p.get("fileName")=="Traces.xcodeproj" and not p.get("repoId")), ""))' "$1")
  if [[ -z $id ]]; then
    say "Adding $XCODEPROJ ($1) to SelfStore" >&2
    id=$(curl -sf -X POST "$API/projects" -H 'Content-Type: application/json' \
      -d "{\"path\":\"$XCODEPROJ\",\"scheme\":\"$1\",\"platform\":\"$2\"}" | json 'd["id"]') || die "Couldn't add $1 to SelfStore"
  fi
  print -r -- $id
}

# Starts a build and waits for it; leaves the final project JSON in $P.
build() {  # id label
  say "Building $2 ($1)…"
  curl -sf -X POST "$API/projects/$1/build" >/dev/null || die "Couldn't start the $2 build"
  local last="" state step
  while true; do
    sleep 5
    P=$(curl -sf "$API/projects/$1")
    state=$(print -r -- $P | json 'd.get("state","")')
    step=$(print -r -- $P | json 'd.get("step") or ""')
    [[ $step != $last ]] && { echo "   $step"; last=$step; }
    case $state in
      succeeded) break ;;
      failed|cancelled) die "$2 build $state: $(print -r -- $P | json 'd.get("error") or d.get("step")'). Log: $API/projects/$1/log" ;;
    esac
  done
}

# 1. iPhone / iPad.
if [[ ${SKIP_IOS:-0} != 1 ]]; then
  IOS=$(project_id Traces-iOS ios)
  curl -sf -X PATCH "$API/projects/$IOS" -H 'Content-Type: application/json' -d '{"exportToRepo": true}' >/dev/null \
    || die "Couldn't turn on export to repo for $IOS"
  build $IOS "iPhone/iPad"
  [[ -f selfstore/Traces-iOS.ipa && -f selfstore.yml ]] || die "The iPhone build didn't export selfstore/Traces-iOS.ipa"
  say "Installable from SelfStore: $(print -r -- $P | json 'd.get("step") or ""')"
  if [[ ${DRY_RUN:-0} != 1 ]]; then
    git add selfstore.yml selfstore/Traces-iOS.ipa
    git diff --cached --quiet -- selfstore.yml selfstore/Traces-iOS.ipa \
      || git commit -q -m "Repo: Traces for iPhone and iPad $(print -r -- $P | json 'd.get("step") or ""' | sed 's/^Built //')" -- selfstore.yml selfstore/Traces-iOS.ipa
  fi
fi
if [[ ${SKIP_MAC:-0} == 1 ]]; then
  [[ ${DRY_RUN:-0} != 1 ]] && git push -q origin HEAD
  say "Done (Mac skipped)"; exit 0
fi

# 2. Mac: build, sign, notarize.
MAC=$(project_id Traces-Mac macos)
build $MAC "Mac"
VERSION=$(print -r -- $P | json 'd.get("version") or ""')
BUILD=$(print -r -- $P | python3 -c 'import json,re,sys; m=re.search(r"\((\d+)\)", json.load(sys.stdin).get("step") or ""); print(m.group(1) if m else "")')
NOTARIZED=$(print -r -- $P | json 'd.get("notarized") is True')
[[ -n $VERSION ]] || die "The build didn't report a version"
[[ $NOTARIZED == True || ${ALLOW_UNNOTARIZED:-0} == 1 ]] || die "The Mac build wasn't notarized (set up Developer ID signing in SelfStore, or ALLOW_UNNOTARIZED=1)"

# 3. Download the artifacts under stable names.
OUT=build/release; mkdir -p $OUT; rm -f $OUT/$APP.dmg $OUT/$APP.zip
for kind in dmg zip; do
  apath=$(print -r -- $P | json "[a['path'] for a in d.get('artifacts') or [] if a['name'].endswith('.$kind')][0]")
  curl -sf "${API%/api}$apath" -o $OUT/$APP.$kind || die "Couldn't download the .$kind"
done
if [[ $NOTARIZED == True ]]; then xcrun stapler validate $OUT/$APP.dmg >/dev/null || die "The dmg isn't stapled"; fi
if [[ ${DRY_RUN:-0} == 1 ]]; then say "Dry run: built $VERSION ($BUILD), notarized=$NOTARIZED → $OUT"; exit 0; fi

# 4. Tag and release.
TAG=v$VERSION
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null || gh release view $TAG >/dev/null 2>&1; then
  TAG=v$VERSION-${BUILD:-$(date -u +%Y%m%d%H%M)}
fi
if [[ -z $NOTES ]]; then
  prev=$(git describe --tags --abbrev=0 2>/dev/null || true)
  if [[ -n $prev ]]; then range=("$prev..HEAD"); else range=(-20); fi
  NOTES=$(git log --pretty='- %s' $range | grep -v '^- Website: \|^- Repo: ' | head -30 || true)
fi
say "Releasing $TAG on $REPO"
git push -q origin HEAD
gh release create $TAG $OUT/$APP.dmg $OUT/$APP.zip --target $(git rev-parse HEAD) \
  --title "$APP $VERSION${BUILD:+ ($BUILD)}" --notes "${NOTES:-$APP $VERSION}" ${DRAFT:+--draft}
git fetch -q --tags

# 5. Point the website at it.
DMG_SIZE=$(stat -f %z $OUT/$APP.dmg)
cat > docs/latest.json <<EOF
{
  "version": "$VERSION",
  "build": "$BUILD",
  "tag": "$TAG",
  "date": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "repo": "$REPO",
  "dmg": "https://github.com/$REPO/releases/download/$TAG/$APP.dmg",
  "zip": "https://github.com/$REPO/releases/download/$TAG/$APP.zip",
  "dmgSize": $DMG_SIZE,
  "minimumSystemVersion": "$(sed -n 's/.*macOS: *"\{0,1\}\([0-9.]*\).*/\1/p' app/project.yml | head -1)",
  "notarized": $([[ $NOTARIZED == True ]] && echo true || echo false)
}
EOF
git add docs
git commit -q -m "Website: $APP $VERSION${BUILD:+ ($BUILD)}" -- docs
git push -q origin HEAD

# 6. GitHub Pages serves docs/ (first deploy only).
enable_pages
say "Done: https://github.com/$REPO/releases/tag/$TAG"
