#!/bin/bash
set -euo pipefail
cd -- "$(dirname -- "$0")"
xcodebuild -resolvePackageDependencies -project LiveShopCamera.xcodeproj -scheme LiveShopCamera
xcodebuild -project LiveShopCamera.xcodeproj -scheme LiveShopCamera -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
device_id=$(xcrun simctl list devices available -j | python3 -c 'import json,sys; d=json.load(sys.stdin); print(next(v["udid"] for k,vs in d["devices"].items() if "iOS" in k for v in vs if "iPhone" in v["name"]))')
xcodebuild -project LiveShopCamera.xcodeproj -scheme LiveShopCamera -destination "platform=iOS Simulator,id=$device_id" CODE_SIGNING_ALLOWED=NO test
