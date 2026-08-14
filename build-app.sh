#!/bin/bash
# 把 SwiftPM 产物打成一个真正的 .app —— MenuBarExtra 需要 bundle 才能正常常驻，
# 而且要靠 Info.plist 里的 LSUIElement 才能不出现在 Dock 和 Cmd-Tab 里。
#
# 用法：
#   ./build-app.sh              只构建
#   ./build-app.sh --install    构建并同时安装 App 和 llmq
#
# 为什么安装一定要成对做：菜单栏 App 和 llmq 是两个独立二进制，却写同一份快照。
# 只更新其中一个，旧的那个会每隔几分钟用它那套过时的采集器把快照覆盖回去，
# 新接的平台数据就这么被静默抹掉 —— 这个坑真踩过一次，排查起来非常费劲。
set -euo pipefail

cd "$(dirname "$0")"

CONFIG="release"
INSTALL=0
for arg in "$@"; do
  case "$arg" in
    --install) INSTALL=1 ;;
    debug|release) CONFIG="$arg" ;;
  esac
done

APP_NAME="LLMQuotaBar"
BUILD_DIR=".build/$CONFIG"
APP_DIR="$BUILD_DIR/$APP_NAME.app"

echo "==> 编译 ($CONFIG)"
swift build -c "$CONFIG"

echo "==> 组装 $APP_NAME.app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BUILD_DIR/LLMQuotaBarApp" "$APP_DIR/Contents/MacOS/$APP_NAME"

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>LLM 额度</string>
  <key>CFBundleIdentifier</key><string>com.llmquotabar.menubar</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <!-- 只活在菜单栏：不占 Dock 图标、不进 Cmd-Tab -->
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# 本地临时签名。没有它的话，重新编译后 macOS 会因为签名失效拒绝启动。
codesign --force --deep --sign - "$APP_DIR" 2>/dev/null || \
  echo "   (跳过签名，不影响本机运行)"

echo "==> 完成: $APP_DIR"

if [ "$INSTALL" -eq 1 ]; then
  echo "==> 安装（App 与 CLI 必须同时更新）"

  # 先停掉在跑的实例，否则替换 bundle 后它仍在用旧代码写快照。
  pkill -f "LLMQuotaBar.app/Contents/MacOS" 2>/dev/null || true
  sleep 1

  rm -rf /Applications/"$APP_NAME".app
  cp -R "$APP_DIR" /Applications/
  codesign --force --deep --sign - /Applications/"$APP_NAME".app 2>/dev/null || true
  echo "   /Applications/$APP_NAME.app"

  # 原子替换，不能直接 cp 覆盖。
  #
  # launchd 的工作循环正在执行 ~/.local/bin/llmq，cp 是就地截断重写，
  # 会让运行中进程的映像失效 —— macOS 直接 SIGKILL，而且这期间新 exec
  # 会拿到写了一半的文件。症状极其迷惑：所有 llmq 命令都退出码 137、
  # 或者退出码 0 但一个字都不输出。踩过一次。
  # 写临时文件再 mv（rename 是原子的），运行中的进程继续持有旧 inode。
  mkdir -p "$HOME/.local/bin"
  cp "$BUILD_DIR/llmq" "$HOME/.local/bin/.llmq.new"
  chmod +x "$HOME/.local/bin/.llmq.new"
  mv -f "$HOME/.local/bin/.llmq.new" "$HOME/.local/bin/llmq"
  echo "   ~/.local/bin/llmq"

  # 循环装成常驻服务时，换了二进制要重启它才会生效。
  if launchctl list 2>/dev/null | grep -q com.llmquotabar.worker; then
    launchctl kickstart -k "gui/$(id -u)/com.llmquotabar.worker" 2>/dev/null \
      && echo "   已重启工作循环（换了二进制）"
  fi

  open /Applications/"$APP_NAME".app
  echo "   已重新启动菜单栏 App"
else
  echo
  echo "安装（推荐，App 和 CLI 一起装，避免版本漂移）："
  echo "  ./build-app.sh --install"
fi
# 本脚本用途：将 SwiftPM 产物组装成 macOS .app bundle（含 Info.plist、签名），可选 --install 同时安装 App 和 llmq CLI 并重启常驻服务。
