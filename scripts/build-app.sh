#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
configuration="${1:-release}"
if [[ "$configuration" != release && "$configuration" != debug ]]; then
    print -u2 "Usage: scripts/build-app.sh [release|debug]"
    exit 2
fi
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$PWD/.build/ModuleCache}"
export SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-$PWD/.build/ModuleCache}"
swift_options=(--cache-path "$PWD/.build/PackageCache")
# A restricted parent sandbox may prevent SwiftPM from creating its own sandbox.
# Opt in explicitly for that environment; ordinary local builds keep the default.
if [[ "${MOLE_SWIFTPM_DISABLE_SANDBOX:-0}" == 1 ]]; then
    swift_options+=(--disable-sandbox)
fi
xcrun swift build -c "$configuration" "${swift_options[@]}"
bin_dir="$(xcrun swift build -c "$configuration" "${swift_options[@]}" --show-bin-path)"
app_dir="$PWD/dist/Qixu.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
mkdir -p "$app_dir/Contents/Library/Helpers"
cp "$bin_dir/MoleRebuild" "$app_dir/Contents/MacOS/Qixu"
cp "$bin_dir/MoleRebuildAdmin" "$app_dir/Contents/Library/Helpers/MoleRebuildAdmin"
/usr/bin/codesign --force --sign - "$app_dir/Contents/Library/Helpers/MoleRebuildAdmin"
cp README.md "$app_dir/Contents/Resources/"
cat > "$app_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
<key>CFBundleLocalizations</key><array><string>zh_CN</string><string>en</string></array>
<key>CFBundleExecutable</key><string>Qixu</string>
<key>CFBundleIdentifier</key><string>dev.local.MoleRebuild</string>
<key>CFBundleName</key><string>Qixu</string>
<key>CFBundleDisplayName</key><string>Qixu</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0.0</string>
<key>CFBundleVersion</key><string>20261103.14</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSAppleEventsUsageDescription</key><string>在你确认维护操作后，请求系统执行选定的管理员命令。</string>
</dict></plist>
PLIST
icon_dir="$PWD/.build/AppIcon.iconset"
mkdir -p "$icon_dir"
xcrun swift scripts/GenerateIcon.swift "$icon_dir"
/usr/bin/iconutil -c icns "$icon_dir" -o "$app_dir/Contents/Resources/AppIcon.icns"
/usr/bin/codesign --force --sign - "$app_dir"
/usr/bin/codesign --verify --strict "$app_dir"
print "已构建：$app_dir"
