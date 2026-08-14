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

# **不往 bundle 里放 llmq。**
#
# 试过：Apple DTS 建议「把命令行工具塞进 app bundle」来拿完全磁盘访问。
# 在这台机器上没解开闸门，却制造了一个真实故障 ——
# worker 的 plist 被指向 bundle 里那份，而 `llmq release publish`
# 只更新 ~/.local/bin/llmq，两份从此分道扬镳：
# worker 安静地跑了几小时的旧二进制（我以为发布生效了），
# 最后那个文件不见了，worker 直接以 EX_CONFIG 退出，队列停了 80 分钟。
#
# 一份二进制、一个更新入口。要再试 bundle 方案，得先让 publish 同时更新两份。

# 图标：现画，不入库二进制资源。
#
# 画的是「三根柱子 + 上面没用掉的那一截」，不是仪表盘 ——
# 这个工具的问题从来是「你有多少额度没用掉」，空的那截才是主角。
# 小尺寸（≤32px）走简化版：淡轮廓在 16px 上会和实心糊成一块，
# 整个图标读成「带缺口的方块」，三根柱子的信息全丢。
ICONSET="$BUILD_DIR/LLMQuotaBar.iconset"
rm -rf "$ICONSET"
if swift Tools/make-icon.swift "$BUILD_DIR" >/dev/null 2>&1 \
   && iconutil -c icns "$ICONSET" -o "$APP_DIR/Contents/Resources/AppIcon.icns" 2>/dev/null; then
  echo "==> 图标已生成"
else
  echo "==> 图标生成失败，先不带图标（不影响运行）"
fi

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
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST


# 签名身份：跨重建稳定，否则每次重装都会作废用户给的系统授权。
#
# adhoc 签名（--sign -）没有 Team ID，系统只能拿 cdhash 认身份，
# 而 cdhash 每次重建都变 —— 实测导致「加了完全磁盘访问，重装一次就没了」，
# 排查时反复横跳了一整轮。和 llmq 共用同一份配置。
# 没配就退回 adhoc，行为和以前一致（这个项目要开源，不能硬编码证书）。
SIGN_ID="${LLMQ_CODESIGN_IDENTITY:-}"
if [ -z "$SIGN_ID" ]; then
  SIGN_CFG="$HOME/Library/Application Support/LLMQuotaBar/signing.json"
  [ -f "$SIGN_CFG" ] && SIGN_ID=$(/usr/bin/python3 -c \
    'import json,sys;print(json.load(open(sys.argv[1])).get("identity",""))' "$SIGN_CFG" 2>/dev/null || true)
fi
if [ -n "$SIGN_ID" ]; then
  echo "==> 用稳定身份签名：$SIGN_ID"
else
  SIGN_ID="-"
  echo "==> 没配签名身份，用 adhoc（系统授权会在下次重装后失效）"
  echo "    配一次：llmq release sign-with \"<证书名>\""
fi

codesign --force --deep --sign "$SIGN_ID" "$APP_DIR" 2>/dev/null || \
  echo "   (签名失败，不影响本机运行)"

echo "==> 完成: $APP_DIR"

if [ "$INSTALL" -eq 1 ]; then
  echo "==> 安装（App 与 CLI 必须同时更新）"

  # 先停掉在跑的实例，否则替换 bundle 后它仍在用旧代码写快照。
  pkill -f "LLMQuotaBar.app/Contents/MacOS" 2>/dev/null || true
  sleep 1

  rm -rf /Applications/"$APP_NAME".app
  cp -R "$APP_DIR" /Applications/
  codesign --force --deep --sign "$SIGN_ID" /Applications/"$APP_NAME".app 2>/dev/null || true
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
  # **CLI 也要签，而且要在 mv 之前签。**
  #
  # 这一步漏过一次：给 .app 加了稳定签名，却忘了同一个脚本还会装 CLI，
  # 于是 --install 一跑就把刚给 llmq 的完全磁盘访问作废了 ——
  # 我前一分钟才让用户去授的权。
  # --identifier 必须显式给：codesign 默认拿文件名当标识，
  # 这里的文件名是 .llmq.new，签出来就是另一个身份。
  codesign --force --sign "$SIGN_ID" --identifier llmq --timestamp=none \
    "$HOME/.local/bin/.llmq.new" 2>/dev/null || echo "   (CLI 签名失败)"
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
