#!/bin/bash
# 把安装包发布到 iCloud，供局域网里其他 Mac 一条命令装上。
#
# 关于安全，有一件事必须说清楚：
#
# SECURITY.md 第一节明确禁止「用 iCloud/共享盘传可执行内容」。这个脚本
# 就是在做那件事。原因是第五节那条等式：能往你 iCloud 写文件的人 = 能在
# 你 Mac 上执行代码的人。如果装机命令无条件执行 iCloud 里的东西，那条
# 等式就从「能投一个任务」升级成「能直接拿到代码执行」。
#
# 所以这里把**信任锚点挪出了 iCloud**：
#
#   - 发布时算出 tar 包的 SHA-256，打印在终端上。
#   - 装机命令里内嵌那串哈希，先校验再解包。
#   - 哈希走的是你复制粘贴的这条命令，不走 iCloud。
#
# 于是 iCloud 里的内容退回成「不可信数据」，由一个来自另一条渠道的哈希
# 来背书。改动 iCloud 里的包会导致校验失败，而不是被静默执行。
#
# 这不是万能的：能改 iCloud 的人如果**同时**能改你看到的这条命令，
# 那还是完蛋。但那已经是另一个量级的入侵了。
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="LLMQuotaBar"
DIST_NAME="llmq-dist"
ICLOUD="$HOME/Library/Mobile Documents/com~apple~CloudDocs/$APP_NAME/dist"

echo "==> 编译通用二进制（Intel + Apple Silicon）"
# 另一台机器可能是 Intel。只发 arm64 的话，在那台上是「zsh: bad CPU type」，
# 报错信息还完全看不出是架构问题。
swift build -c release --arch arm64 --arch x86_64
BIN=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)

STAGE=$(mktemp -d)/"$DIST_NAME"
mkdir -p "$STAGE"

echo "==> 组装 .app"
APP="$STAGE/$APP_NAME.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/LLMQuotaBarApp" "$APP/Contents/MacOS/$APP_NAME"
sed -n '/<?xml/,/<\/plist>/p' /dev/null 2>/dev/null || true
cat > "$APP/Contents/Info.plist" <<PLIST
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
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# SwiftPM 的资源 bundle 也得带上，否则看板页面出不来。
for b in "$BIN"/*.bundle; do
  [ -e "$b" ] && cp -R "$b" "$APP/Contents/Resources/" || true
done
codesign --force --deep --sign - "$APP" 2>/dev/null || true

cp "$BIN/llmq" "$STAGE/llmq"
chmod +x "$STAGE/llmq"

echo "==> 写安装脚本"
cat > "$STAGE/install.sh" <<'INSTALL'
#!/bin/bash
# 由外层命令校验过 SHA-256 之后才会跑到这里。
set -euo pipefail
cd "$(dirname "$0")"
APP_NAME="LLMQuotaBar"

echo "==> 安装 $APP_NAME"

# 停掉在跑的旧实例。菜单栏 App 和 llmq 写同一份快照，
# 只换一个会让旧的那个用过时采集器把数据覆盖回去。
pkill -f "$APP_NAME.app/Contents/MacOS" 2>/dev/null || true
sleep 1

# iCloud 同步过来的文件可能带隔离属性，带着它 .app 打不开。
# 这里敢摘是因为外层已经用哈希验过整个包了。
xattr -dr com.apple.quarantine . 2>/dev/null || true

rm -rf /Applications/"$APP_NAME".app
cp -R "$APP_NAME.app" /Applications/
codesign --force --deep --sign - /Applications/"$APP_NAME".app 2>/dev/null || true
echo "   /Applications/$APP_NAME.app"

# 原子替换。直接 cp 覆盖会让正在运行的进程映像失效，
# macOS 直接 SIGKILL，症状是所有命令退出码 137 或者退出码 0 但没输出。
mkdir -p "$HOME/.local/bin"
cp llmq "$HOME/.local/bin/.llmq.new"
chmod +x "$HOME/.local/bin/.llmq.new"
mv -f "$HOME/.local/bin/.llmq.new" "$HOME/.local/bin/llmq"
echo "   ~/.local/bin/llmq"

if launchctl list 2>/dev/null | grep -q com.llmquotabar.worker; then
  launchctl kickstart -k "gui/$(id -u)/com.llmquotabar.worker" 2>/dev/null \
    && echo "   已重启工作循环"
fi

open /Applications/"$APP_NAME".app 2>/dev/null || true

echo
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *)
    echo "注意：~/.local/bin 不在 PATH 里。加一行："
    echo "  echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.zshrc && source ~/.zshrc"
    echo ;;
esac
echo "装好了。下一步："
echo "  llmq doctor      看这台机器认出了哪些平台"
echo "  llmq collect     采一次，数据会同步到 iCloud 汇总"
INSTALL
chmod +x "$STAGE/install.sh"

echo "==> 打包"
mkdir -p "$ICLOUD"
TAR="$ICLOUD/$DIST_NAME.tar.gz"
# --no-mac-metadata：不带 ._ 附属文件，否则解包后一堆垃圾，
# 而且这些元数据会让不同机器上算出的哈希不稳定。
tar --no-mac-metadata -czf "$TAR" -C "$(dirname "$STAGE")" "$DIST_NAME"
rm -rf "$(dirname "$STAGE")"

SHA=$(shasum -a 256 "$TAR" | awk '{print $1}')
SIZE=$(du -h "$TAR" | awk '{print $1}')

# 哈希也写一份到 iCloud，但那只是给你自己核对用的 ——
# 装机命令里的哈希必须来自终端输出，不能来自这个文件。
# 攻击者能改包就能改这个文件，它证明不了任何事。
echo "$SHA" > "$ICLOUD/$DIST_NAME.sha256"

echo
echo "==> 发布完成  $TAR  ($SIZE)"
echo
echo "───── 方式一：AirDrop（推荐）─────"
echo "把这个文件隔空投送过去："
echo "  $TAR"
echo "然后在那台机器上跑："
echo
cat <<CMD
T=\$(mktemp -d) && tar xzf ~/Downloads/$DIST_NAME.tar.gz -C "\$T" && "\$T/$DIST_NAME/install.sh"
CMD
echo
echo "AirDrop 是点对点直传，不落在任何可写的共享位置 ——"
echo "所以不需要校验哈希：能改这个包的人得先能改传输本身。"
echo
echo "───── 方式二：iCloud ─────"
echo "包已经在 iCloud 里了，在那台机器上贴这一条："
echo
cat <<CMD
D=~/Library/Mobile\\ Documents/com~apple~CloudDocs/LLMQuotaBar/dist; brctl download "\$D" 2>/dev/null; until [ -f "\$D/$DIST_NAME.tar.gz" ]; do sleep 1; done; echo "$SHA  \$D/$DIST_NAME.tar.gz" | shasum -a 256 -c - && T=\$(mktemp -d) && tar xzf "\$D/$DIST_NAME.tar.gz" -C "\$T" && "\$T/$DIST_NAME/install.sh"
CMD
echo
echo "这条里内嵌了哈希，会先校验再解包。哈希走的是你复制的这条命令，"
echo "不走 iCloud —— iCloud 里那个 .sha256 文件只是给你自己核对用的，"
echo "能改包的人也能改它，它证明不了任何事。"
echo
