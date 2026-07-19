#!/bin/zsh

set -euo pipefail

PROJECT_ROOT="${0:A:h:h}"
DERIVED_DATA="${PROJECT_ROOT}/.build"
APP_BUNDLE="${PROJECT_ROOT}/dist/Argus.app"
BUILT_APP="${DERIVED_DATA}/Build/Products/Release/Argus.app"

xcodebuild \
    -project "${PROJECT_ROOT}/Metrics.xcodeproj" \
    -scheme Metrics \
    -configuration Release \
    -destination "generic/platform=macOS" \
    -derivedDataPath "${DERIVED_DATA}" \
    CODE_SIGNING_ALLOWED=NO \
    build

rm -rf "${APP_BUNDLE}" "${PROJECT_ROOT}/dist/Metrics.app"
mkdir -p "${PROJECT_ROOT}/dist"
ditto "${BUILT_APP}" "${APP_BUNDLE}"

if [[ "${CODE_SIGN_IDENTITY:--}" == "-" ]]; then
    codesign --force --sign - --timestamp=none "${APP_BUNDLE}"
else
    codesign \
        --force \
        --options runtime \
        --sign "${CODE_SIGN_IDENTITY}" \
        --timestamp \
        "${APP_BUNDLE}"
fi

codesign --verify --deep --strict --verbose=2 "${APP_BUNDLE}"
echo "Built ${APP_BUNDLE}"
