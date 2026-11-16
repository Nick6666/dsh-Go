#!/usr/bin/env bash
# Builds the iOS app and packs an installable IPA. No Apple team is configured and
# nothing is uploaded: the archive is unsigned, so whoever installs it re-signs it
# with their own certificate (Xcode, AltStore, Sideloadly), see docs/release-ios.md.
#
#   tooling/ios/build-ipa.sh                     release, unsigned IPA into dist-ios/
#   tooling/ios/build-ipa.sh --dry-run           print the commands, build nothing
#   tooling/ios/build-ipa.sh --build-name 1.2.0  version name instead of app/pubspec.yaml's
#   tooling/ios/build-ipa.sh -- --dart-define=K=V   extra flags for `flutter build ios`
#
#   --release | --debug | --profile  default --release
#   --build-name X.Y.Z               version name (CFBundleShortVersionString)
#   -n, --build-number N             CFBundleVersion instead of the build minute
#   -o, --output DIR                 where the IPA and SHA256SUMS go; default dist-ios/
#   --remote-only                    refuse a build without app/ios/Engine (see below)
#   --allow-missing-engine           do not stop when a prepared engine was left out
#   --dry-run                        print what would run
#   --force                          overwrite an IPA this version already produced
#
# The engine is embedded only when `tooling/ios/prepare-engine.sh` has produced
# app/ios/Engine/.ready. That build also compiles the iSH guest, which needs
# clang, ld.lld, meson and ninja (docs/architecture.md); without it the IPA still
# works, it just reaches remote hosts instead of running DSH on the phone. The
# script therefore checks the produced .app and fails instead of shipping a
# remote-only app by accident when the engine is present but was not embedded.
#
# The version number is the build minute in UTC+8 (tooling/build_number.py), the
# same sequence the Android APKs use, so an IPA built later always carries a
# higher CFBundleVersion than one built earlier.
set -euo pipefail

ROOT=$(CDPATH= cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
APP="$ROOT/app"
ENGINE="$APP/ios/Engine"
PYTHON=${PYTHON:-python3}

usage() { sed -n '2,26p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
die() { echo "build-ipa: $*" >&2; exit 1; }

mode=release name='' code='' out="$ROOT/dist-ios" remote_only=0 allow_missing=0 dry=0 force=0
extra=()
while (($#)); do
  case "$1" in
    --release | --debug | --profile) mode=${1#--}; shift ;;
    --build-name) name=${2:?--build-name needs a version}; shift 2 ;;
    --build-name=*) name=${1#*=}; shift ;;
    -n | --build-number) code=${2:?--build-number needs a number}; shift 2 ;;
    --build-number=*) code=${1#*=}; shift ;;
    -o | --output) out=${2:?--output needs a directory}; shift 2 ;;
    --output=*) out=${1#*=}; shift ;;
    --remote-only) remote_only=1; shift ;;
    --allow-missing-engine) allow_missing=1; shift ;;
    --dry-run) dry=1; shift ;;
    --force) force=1; shift ;;
    -h | --help) usage; exit 0 ;;
    --) shift; extra=("$@"); break ;;
    *) usage >&2; die "unknown option: $1" ;;
  esac
done
for arg in ${extra[@]+"${extra[@]}"}; do
  case "$arg" in
    --build-number* | --build-name* | --no-codesign | --release | --debug | --profile | \
      --release=* | --debug=* | --profile=* | --no-release | --no-debug | --no-profile)
      die "$arg is set by this script; use its own options" ;;
    --codesign | --export-method* | --export-options-plist*)
      die "signing and export are not part of this script; see docs/release-ios.md" ;;
  esac
done

# Version name: pubspec's `version:` without the `+N` placeholder.
if [[ -z $name ]]; then
  name=$(sed -n 's/^version:[[:space:]]*\([^+[:space:]]*\).*/\1/p' "$APP/pubspec.yaml")
fi
[[ $name =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]] || die "not a version name: '$name'"
if [[ -z $code ]]; then
  code=$("$PYTHON" "$ROOT/tooling/build_number.py") ||
    die "cannot stamp the build number (needs python3.10+; set PYTHON)"
fi
[[ $code =~ ^[1-9][0-9]{0,9}$ ]] || die "not a CFBundleVersion: '$code'"
((code <= 2100000000)) || die "CFBundleVersion above Apple's limit: $code"

engine_ready=0
if [[ -f "$ENGINE/.ready" && $remote_only -eq 0 ]]; then engine_ready=1; fi
if [[ $remote_only -eq 1 && -f "$ENGINE/.ready" ]]; then
  die "app/ios/Engine is prepared; move it away for a deliberately remote-only build"
fi

# zip runs from the staging directory, so the output has to be absolute first.
mkdir -p "$out"
out=$(cd "$out" && pwd -P)

apk_like="dsh-go-$name-ios-arm64$([[ $engine_ready -eq 1 ]] || echo '-remote').ipa"
if [[ $mode != release ]]; then apk_like="dsh-go-$name-ios-$mode.ipa"; fi
ipa="$out/$apk_like"
[[ $force -eq 1 ]] || [[ ! -e $ipa ]] || die "$ipa exists; bump the version or pass --force"

cmds=(
  flutter build ios "--$mode" --no-codesign
  --build-name "$name" --build-number "$code"
  "--dart-define=DSH_APP_VERSION=$name+$code"
)
if ((${#extra[@]:-0})); then cmds+=(${extra[@]+"${extra[@]}"}); fi
if [[ $dry == 1 ]]; then
  printf 'cd %q && %q' "$APP" "${cmds[0]}"
  printf ' %q' "${cmds[@]:1}"
  printf '\nmkdir -p %q/Payload && cp -R %q/build/ios/iphoneos/Runner.app %q/Payload/ && (cd %q && zip -qry -X %q Payload)\n' \
    "$out" "$APP" "$out" "$out" "$ipa"
  exit 0
fi

command -v flutter >/dev/null || die "flutter is not on PATH"
[[ -n ${DEVELOPER_DIR:-} || $(xcode-select -p 2>/dev/null) ]] || die "select Xcode first (xcode-select)"

# A prepared engine that is newer than the app reads as a stale build, so the
# mtime of .ready is compared instead of trusting the flag alone.
if [[ $engine_ready -eq 1 ]]; then
  echo "build-ipa: engine prepared; the Xcode phase compiles the native addons and the iSH guest" >&2
fi

cd "$APP"
"${cmds[@]}"

BUILT="$APP/build/ios/iphoneos/Runner.app"
[[ -d $BUILT ]] || die "flutter build produced no device app at $BUILT"

plist="$BUILT/Info.plist"
built_name=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")
built_code=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")
[[ $built_name == "$name" ]] || die "built version name is $built_name, expected $name"
[[ $built_code == "$code" ]] || die "built CFBundleVersion is $built_code, expected $code"

has_runtime=0
[[ -f "$BUILT/dsh-runtime/runtime.zip" && -d "$BUILT/Frameworks/NodeMobile.framework" ]] && has_runtime=1
if [[ $engine_ready -eq 1 && $has_runtime -eq 0 ]]; then
  die "app/ios/Engine was prepared but the app has no embedded runtime (NodeMobile + dsh-runtime)"
fi
if [[ $engine_ready -eq 0 && $has_runtime -eq 1 && $allow_missing -eq 0 ]]; then
  die "the app carries a runtime without a prepared engine; run tooling/ios/prepare-engine.sh"
fi
if [[ $has_runtime -eq 0 ]]; then
  echo "build-ipa: no engine in this IPA — it only connects to remote hosts" >&2
fi
if [[ -f "$BUILT/Frameworks/NodeMobile.framework/NodeMobile" ]] &&
  ! xcrun lipo -verify_arch arm64 "$BUILT/Frameworks/NodeMobile.framework/NodeMobile" >/dev/null 2>&1; then
  die "the embedded NodeMobile is not arm64"
fi

stage=$(mktemp -d "$out/.stage.XXXXXX")
trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/Payload"
cp -R "$BUILT" "$stage/Payload/Runner.app"
# Finder metadata would make the digest differ between machines; zip -X drops it.
(cd "$stage" && zip -qry -X "$ipa" Payload)
trap - EXIT
rm -rf "$stage"

size=$(stat -f %z "$ipa")
digest=$(shasum -a 256 "$ipa" | cut -d' ' -f1)
( cd "$out" && printf '%s  %s\n' "$digest" "$(basename "$ipa")" >SHA256SUMS )
printf 'IPA:    %s (%s bytes)\nSHA256: %s\n' "$ipa" "$size" "$digest"
printf 'Runtime: %s\n' "$([[ $has_runtime -eq 1 ]] && echo 'embedded (DSH runs on the phone)' || echo 'remote hosts only')"
