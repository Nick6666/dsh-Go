#!/usr/bin/env bash
# Builds the app for a physical iPhone and installs it over CoreDevice. The Apple
# identity stays outside the repository: this script only passes the team id on
# the command line, so nothing about a person's account ends up in git.
#
#   tooling/ios/install-device.sh --team TEAMID
#   tooling/ios/install-device.sh --team TEAMID --device UDID
#   tooling/ios/install-device.sh --list
#
#   --team TEAMID      Development team. Xcode must be signed in to that Apple ID
#                      (Xcode → Settings → Accounts) so it can create the profile.
#   --device UDID      Default: the only connected physical device.
#   --build-name X.Y.Z / -n N   version name and CFBundleVersion, as in build-ipa.sh.
#   --list             Print connected devices and exit.
#   --dry-run          Print the commands, build nothing.
#
# A personal team (free Apple ID) cannot use App Groups, so the share extension and
# the companion widget will fail to sign there. Remove those two targets in Xcode
# for such a build; the app itself runs without them.
set -euo pipefail

ROOT=$(CDPATH= cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
APP="$ROOT/app"
PYTHON=${PYTHON:-python3}
BUNDLE=io.github.ccch1mneyyy.dshgo

usage() { sed -n '2,21p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
die() { echo "install-device: $*" >&2; exit 1; }

team='' device='' name='' code='' dry=0
while (($#)); do
  case "$1" in
    --team) team=${2:?--team needs a team id}; shift 2 ;;
    --team=*) team=${1#*=}; shift ;;
    --device) device=${2:?--device needs a UDID}; shift 2 ;;
    --device=*) device=${1#*=}; shift ;;
    --build-name) name=${2:?--build-name needs a version}; shift 2 ;;
    --build-name=*) name=${1#*=}; shift ;;
    -n | --build-number) code=${2:?--build-number needs a number}; shift 2 ;;
    --build-number=*) code=${1#*=}; shift ;;
    --dry-run) dry=1; shift ;;
    --list) LIST=1; shift ;;
    -h | --help) usage; exit 0 ;;
    *) usage >&2; die "unknown option: $1" ;;
  esac
done

# CoreDevice reports physical devices beside simulators; only the physical ones
# can take this build.
devices() {
  local json
  json=$(mktemp)
  xcrun devicectl list devices --json-output "$json" >/dev/null 2>&1 || {
    rm -f "$json"
    die "devicectl cannot list devices"
  }
  "$PYTHON" - "$json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
for entry in data.get("result", {}).get("devices", []):
    hardware = entry.get("hardwareProperties", {})
    # A paired watch is physical too but cannot take this build.
    if hardware.get("reality") != "physical":
        continue
    if not hardware.get("productType", "").startswith(("iPhone", "iPad")):
        continue
    connection = entry.get("connectionProperties", {})
    print("%s\t%s\t%s\t%s" % (
        entry.get("identifier", "?"),
        hardware.get("marketingName", "?"),
        hardware.get("udid", "?"),
        connection.get("transportType", "?"),
    ))
PY
  rm -f "$json"
}

if [[ ${LIST:-0} == 1 ]]; then
  devices
  exit 0
fi

[[ -n $team ]] || die "--team is required (see --help)"
command -v flutter >/dev/null || die "flutter is not on PATH"

if [[ -z $device ]]; then
  found=$(devices)
  [[ -n $found ]] || die "no physical device connected"
  count=$(printf '%s\n' "$found" | wc -l | tr -d ' ')
  ((count == 1)) || die "several devices connected; pick one with --device"
  device=$(printf '%s\n' "$found" | cut -f1)
fi
printf 'install-device: %s\n' "$device" >&2

if [[ -z $name ]]; then
  name=$(sed -n 's/^version:[[:space:]]*\([^+[:space:]]*\).*/\1/p' "$APP/pubspec.yaml")
fi
[[ $name =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]] || die "not a version name: '$name'"
if [[ -z $code ]]; then
  code=$("$PYTHON" "$ROOT/tooling/build_number.py") || die "cannot stamp the build number (needs python3.10+; set PYTHON)"
fi

build=(
  xcodebuild -workspace ios/Runner.xcworkspace -scheme Runner -configuration Release
  -destination 'generic/platform=iOS' -allowProvisioningUpdates -quiet
  "DEVELOPMENT_TEAM=$team"
  "PRODUCT_BUNDLE_IDENTIFIER=$BUNDLE"
  build
)
if [[ $dry == 1 ]]; then
  printf 'cd %q && flutter build ios --release --config-only --build-name %q --build-number %q\n' \
    "$APP" "$name" "$code"
  printf 'cd %q && %q' "$APP" "${build[0]}"
  printf ' %q' "${build[@]:1}"
  printf '\nxcrun devicectl device install app --device %q %q\n' "$device" "$APP/build/ios/iphoneos/Runner.app"
  exit 0
fi

cd "$APP"
flutter build ios --release --config-only --build-name "$name" --build-number "$code"
"${build[@]}" 2>&1 | tee /tmp/dsh-ios-install-build.log | grep -E "error:|warning: .*sign" || true
[[ ${PIPESTATUS[0]} -eq 0 ]] || die "the signed build failed; see the errors above"

BUILT="$APP/build/ios/iphoneos/Runner.app"
[[ -d $BUILT ]] || die "no app at $BUILT"
identity=$(codesign -dv "$BUILT" 2>&1 | sed -n 's/^Authority=//p' | head -1)
[[ -n $identity ]] || die "the built app is not signed"
printf 'install-device: signed by %s\n' "$identity" >&2

xcrun devicectl device install app --device "$device" "$BUILT"
xcrun devicectl device process launch --device "$device" "$BUNDLE" || true
