#!/bin/bash
# Local build preparation only. Never uploads, notarizes, installs, or publishes.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

usage() {
    cat <<'HELP'
Usage: bash Scripts/release.sh COMMAND [ARGS]
  test [OUTPUT]                Run app tests, without signing (host architecture).
  archive-unsigned [OUTPUT]    Build an arm64 rehearsal archive. Not distributable.
  archive [OUTPUT]             Build a locally signed arm64 archive using Xcode settings.
  export ARCHIVE OUTPUT       Export with Developer ID; requires installed signing assets.
  inspect APP                 Check app contents and metadata (unsigned builds allowed).
  verify APP                  Also require Developer ID, runtime and valid signature.
  verify-notarized APP         Also require stapled ticket and Gatekeeper acceptance.

OUTPUT defaults to a fresh directory under build/release. No network upload is performed.
MACPEARL_BUILD_NUMBER optionally overrides the archive's numeric build number.
MACPEARL_VERSION optionally overrides the archive's marketing version (X.Y.Z).
Model redistribution permission and device testing are separate release gates.
HELP
}

command="${1:-help}"
if [[ $# -gt 0 ]]; then shift; fi
case "$command" in
    test|archive|archive-unsigned)
        [[ $# -le 1 ]] || { usage; exit 2; }
        if [[ -n "${MACPEARL_BUILD_NUMBER:-}" && ! "${MACPEARL_BUILD_NUMBER:-}" =~ ^[1-9][0-9]*$ ]]; then
            echo 'MACPEARL_BUILD_NUMBER must be a positive integer.' >&2; exit 2
        fi
        if [[ -n "${MACPEARL_VERSION:-}" && ! "${MACPEARL_VERSION:-}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo 'MACPEARL_VERSION must have the form X.Y.Z.' >&2; exit 2
        fi
        if [[ $# == 1 ]]; then
            output="$1"
            [[ ! -e "$output" ]] || { echo "Choose a new output directory: $output" >&2; exit 1; }
            mkdir -p "$output"
        else
            mkdir -p build/release
            output="$(mktemp -d "$ROOT/build/release/$command.XXXXXX")"
        fi
        output="$(cd "$output" && pwd)"
        echo "Output: $output"
        common=(-project MacPearl.xcodeproj -scheme MacPearl-Release -derivedDataPath "$output/DerivedData")
        if [[ "$command" == test ]]; then
            xcodebuild "${common[@]}" -configuration Debug -destination "platform=macOS,arch=$(uname -m)" \
                -resultBundlePath "$output/Tests.xcresult" CODE_SIGNING_ALLOWED=NO test
        else
            # Bash 3.2 treats an empty array as unset under nounset. Positional
            # arguments support the empty case safely, including with set -u.
            set --
            if [[ "$command" == archive-unsigned ]]; then set -- CODE_SIGNING_ALLOWED=NO; fi
            if [[ -n "${MACPEARL_BUILD_NUMBER:-}" ]]; then set -- "$@" "CURRENT_PROJECT_VERSION=$MACPEARL_BUILD_NUMBER"; fi
            if [[ -n "${MACPEARL_VERSION:-}" ]]; then set -- "$@" "MARKETING_VERSION=$MACPEARL_VERSION"; fi
            xcodebuild "${common[@]}" -configuration Release -destination 'generic/platform=macOS' \
                -archivePath "$output/MacPearl.xcarchive" ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
                "$@" archive
            python3 Scripts/verify-release.py --archive "$output/MacPearl.xcarchive"
            echo 'Archive prepared locally. This is not a notarized download.'
        fi
        ;;
    export)
        [[ $# == 2 ]] || { usage; exit 2; }
        [[ -d "$1" && ! -e "$2" ]] || { echo 'Provide an existing archive and a new output path.' >&2; exit 1; }
        python3 Scripts/verify-release.py --archive "$1"
        xcodebuild -exportArchive -archivePath "$1" -exportPath "$2" -exportOptionsPlist Scripts/ExportOptions.plist
        python3 Scripts/verify-release.py --signed "$2/MacPearl.app"
        ;;
    inspect|verify|verify-notarized)
        [[ $# == 1 ]] || { usage; exit 2; }
        if [[ "$command" != inspect ]]; then set -- --signed "$@"; fi
        if [[ "$command" == verify-notarized ]]; then set -- --notarized "$@"; fi
        python3 Scripts/verify-release.py "$@"
        ;;
    help|-h|--help) usage ;;
    *) usage; exit 2 ;;
esac
