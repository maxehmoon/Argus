#!/bin/zsh

set -euo pipefail

PROJECT_ROOT="${0:A:h:h}"
DERIVED_DATA="${PROJECT_ROOT}/.build"
APP_BUNDLE="${PROJECT_ROOT}/dist/Argus.app"
BUILT_APP="${DERIVED_DATA}/Build/Products/Release/Argus.app"
SIGN_IDENTITY="${CODE_SIGN_IDENTITY:--}"
if [[ "${SIGN_IDENTITY}" == "-" ]]; then
    HARDENED_RUNTIME=NO
else
    HARDENED_RUNTIME=YES
fi

xcodebuild \
    -project "${PROJECT_ROOT}/Metrics.xcodeproj" \
    -scheme Metrics \
    -configuration Release \
    -destination "generic/platform=macOS" \
    -derivedDataPath "${DERIVED_DATA}" \
    CODE_SIGNING_ALLOWED=YES \
    CODE_SIGN_IDENTITY="${SIGN_IDENTITY}" \
    ENABLE_HARDENED_RUNTIME="${HARDENED_RUNTIME}" \
    build

rm -rf "${APP_BUNDLE}" "${PROJECT_ROOT}/dist/Metrics.app"
mkdir -p "${PROJECT_ROOT}/dist"
ditto "${BUILT_APP}" "${APP_BUNDLE}"

codesign --verify --deep --strict --verbose=2 "${APP_BUNDLE}"
echo "Built ${APP_BUNDLE}"
