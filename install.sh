#!/bin/bash
# ReadyToWhip 自动化安装/测试脚本
set -e

APP_NAME="ReadyToWhip"
INSTALL_PATH="/Applications/${APP_NAME}.app"
BUILD_DIR=".build/release"
APP_BUNDLE=".build/${APP_NAME}.app"

echo "🚀 正在编译 ${APP_NAME} (Release 模式)..."
swift build -c release

echo "📦 正在创建 App Bundle 结构..."
rm -rf "${APP_BUNDLE}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"

echo "📂 正在拷贝二进制文件..."
cp "${BUILD_DIR}/${APP_NAME}" "${APP_BUNDLE}/Contents/MacOS/"

echo "📄 正在注入 Info.plist..."
if [ -f "Info.plist" ]; then
    cp Info.plist "${APP_BUNDLE}/Contents/"
else
    echo "⚠️ 未找到 Info.plist，使用默认配置..."
    # 这里的备份逻辑防止脚本在没有 Info.plist 的情况下失败
    cat > "${APP_BUNDLE}/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>com.readytowhip.app</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
EOF
fi

echo "🛑 正在关闭当前运行的实例..."
pkill -x "${APP_NAME}" || true

echo "🧹 正在执行覆盖安装到 /Applications..."
rm -rf "${INSTALL_PATH}"
cp -R "${APP_BUNDLE}" /Applications/

# 刷新 macOS 的 Launch Services 缓存，确保系统知道应用已更新
/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister -f "${INSTALL_PATH}"

echo "▶️ 正在启动新版本..."
open "${INSTALL_PATH}"

echo "✅ 安装成功！ReadyToWhip 已在运行。"
