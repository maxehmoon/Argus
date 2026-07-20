#!/bin/zsh

set -euo pipefail

PROJECT_ROOT="${0:A:h:h}"
APP_BUNDLE="${PROJECT_ROOT}/dist/Argus.app"
DMG_PATH="${PROJECT_ROOT}/dist/Argus.dmg"

if [[ ! -d "${APP_BUNDLE}" ]]; then
    echo "Argus.app was not found. Run ./Scripts/build-app.sh first." >&2
    exit 1
fi

STAGING_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/argus-dmg.XXXXXX")"
trap 'rm -rf "${STAGING_ROOT}"' EXIT

STAGING_VOLUME="${STAGING_ROOT}/Argus"
TEMP_DMG="${STAGING_ROOT}/Argus.dmg"
mkdir -p "${STAGING_VOLUME}"
ditto "${APP_BUNDLE}" "${STAGING_VOLUME}/Argus.app"
ln -s /Applications "${STAGING_VOLUME}/Applications"

mkdir -p "${PROJECT_ROOT}/dist"
if diskutil image create from --help 2>&1 | grep -q -- '--volumeName'; then
    diskutil image create from \
        --volumeName "Argus" \
        --format UDZO \
        "${STAGING_VOLUME}" \
        "${TEMP_DMG}"
else
    hdiutil create \
        -volname "Argus" \
        -srcfolder "${STAGING_VOLUME}" \
        -format UDZO \
        "${TEMP_DMG}"
fi
hdiutil verify "${TEMP_DMG}"
mv -f "${TEMP_DMG}" "${DMG_PATH}"

echo "Built ${DMG_PATH}"
