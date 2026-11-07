#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
app="${1:-$project_root/.build-release/Build/Products/Release/tourXbox.app}"
[[ -d "$app" ]] || { printf 'Application not found: %s\n' "$app" >&2; exit 1; }
codesign --verify --deep --strict "$app"
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app/Contents/Info.plist")
archs=$(lipo -archs "$app/Contents/MacOS/tourXbox")
arch_label="${archs// /-}"
out="$project_root/dist/tourXbox-$version-macOS-$arch_label.dmg"
[[ ! -e "$out" ]] || { printf 'Already exists: %s\n' "$out" >&2; exit 1; }
stage=$(mktemp -d "${TMPDIR:-/tmp}/tourXbox-dmg.XXXXXX")
trap 'rm -rf "$stage"' EXIT
ditto "$app" "$stage/tourXbox.app"
ln -s /Applications "$stage/Applications"
cat > "$stage/安装说明.txt" <<'INSTALL'
将 tourXbox 拖入 Applications 后启动。已有用户请继续使用原来的安装路径，避免保留多个运行副本。

本版本为 Apple Silicon 构建，部署目标 macOS 14；Liquid Glass 需要 macOS 26 或更高版本。
当前应用采用临时签名，未公证。需要辅助功能／事件发送许可；Photoshop 调色连接另需自动化许可。

下载与源码：https://github.com/ZZZzcxZZZ/tourXbox
INSTALL
mkdir -p "$project_root/dist"
hdiutil create -volname "tourXbox $version" -srcfolder "$stage" -fs HFS+ -format UDZO -ov "$out"
hdiutil verify "$out"
(cd "$project_root/dist" && shasum -a 256 "$(basename "$out")" > SHA256SUMS.txt)
printf 'Packaged: %s\n' "$out"
