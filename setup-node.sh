#!/bin/bash
# 给局域网里另一台 Mac 做一个「一次性入职包」，一条命令装完就能互相派活。
#
# 用法：./setup-node.sh <节点名>
#
# 包里有：通用二进制的 llmq 和 .app、那台机器的客户端证书、CA 证书、
# 连接配置，以及口令。
#
# ── 口令和证书跟软件放在同一个包里，这样安全吗
#
# 先说结论：**在这个具体的威胁模型下不会让情况变差**，但这个包是一次性的，
# 装完就会自己从 iCloud 删掉。
#
# 推理是这样的。SECURITY.md 第五节已经写死了一条等式：
#
#     能往你 iCloud Drive 写文件的人 = 能在你 Mac 上执行代码的人
#
# 因为收件箱里的任务会被 agent 直接执行。既然「能写 iCloud」已经等于
# 代码执行，那再往里放一张只能「投一个任务」的客户端证书，权限严格更小 ——
# 没有扩大爆炸半径。
#
# 至于「能读 iCloud」的人：他有你的 Apple ID，那他本来就能写。同一个人。
#
# 真正需要防的是**篡改**：有人换掉包里的 llmq 二进制，那就是直接的代码执行，
# 而且是在你主动运行安装命令时发生的。所以装机命令里内嵌 SHA-256，
# 哈希走你复制的那条命令，不走 iCloud。
#
# 口令因此是仪式性的 —— 它和它保护的文件在同一个包里。留着它只是因为
# p12 格式要求有，别把它当成一道防线。真正的防线是那串哈希，
# 和「装完就删」这个动作。
set -euo pipefail
cd "$(dirname "$0")"

NODE="${1:-}"
if [ -z "$NODE" ]; then
  echo "用法：./setup-node.sh <节点名>    例：./setup-node.sh macbook-pro-intel"
  exit 2
fi

APP_NAME="LLMQuotaBar"
CLUSTER="$HOME/Library/Application Support/$APP_NAME/cluster"
ICLOUD="$HOME/Library/Mobile Documents/com~apple~CloudDocs/$APP_NAME/dist"
BUNDLE="llmq-setup-$NODE"
LLMQ="$HOME/.local/bin/llmq"

ME=$("$LLMQ" cluster status | awk '/^本机节点/{print $2}')
IP=$("$LLMQ" cluster status | grep -o '本机内网地址 [0-9.]*' | awk '{print $2}')
PORT=$("$LLMQ" cluster status | awk '/^监听端口/{print $2}' | tr -d '（只在跑serve时才绑')
[ -n "$IP" ] || { echo "找不到本机内网地址，没连网？"; exit 1; }

echo "==> 编译通用二进制（Intel + Apple Silicon）"
swift build -c release --arch arm64 --arch x86_64 >/dev/null
BIN=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)

echo "==> 给 $NODE 签发证书"
# 重签一张。旧的那张作废不了（私有 CA 没有 CRL），但反正它没发出去过；
# 真发出去过的话，撤销手段是允许名单，不是证书本身。
rm -f "$CLUSTER/$NODE.p12"
PW=$("$LLMQ" cluster enroll "$NODE" | grep '口令' | sed 's/.*口令 //' | sed $'s/\033\\[[0-9;]*m//g')
[ -n "$PW" ] || { echo "签发失败"; exit 1; }

STAGE=$(mktemp -d)/"$BUNDLE"
mkdir -p "$STAGE"

echo "==> 组装 .app"
APP="$STAGE/$APP_NAME.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/LLMQuotaBarApp" "$APP/Contents/MacOS/$APP_NAME"
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
for b in "$BIN"/*.bundle; do [ -e "$b" ] && cp -R "$b" "$APP/Contents/Resources/"; done
codesign --force --deep --sign - "$APP" 2>/dev/null || true

cp "$BIN/llmq" "$STAGE/llmq"
chmod +x "$STAGE/llmq"
cp "$CLUSTER/$NODE.p12" "$STAGE/node.p12"
cp "$CLUSTER/ca.crt" "$STAGE/ca.crt"

cat > "$STAGE/node.env" <<ENV
NODE_NAME="$NODE"
SERVER_NAME="$ME"
SERVER_ADDR="$IP:$PORT"
P12_PASS="$PW"
ENV
chmod 600 "$STAGE/node.env"

echo "==> 写安装脚本"
cat > "$STAGE/install.sh" <<'INSTALL'
#!/bin/bash
# 外层命令校验过 SHA-256 才会跑到这里。
set -euo pipefail
cd "$(dirname "$0")"
source ./node.env
APP_NAME="LLMQuotaBar"
CLUSTER="$HOME/Library/Application Support/$APP_NAME/cluster"

echo "==> 1/4 安装软件"
pkill -f "$APP_NAME.app/Contents/MacOS" 2>/dev/null || true
sleep 1
xattr -dr com.apple.quarantine . 2>/dev/null || true

rm -rf /Applications/"$APP_NAME".app
cp -R "$APP_NAME.app" /Applications/
codesign --force --deep --sign - /Applications/"$APP_NAME".app 2>/dev/null || true

# 原子替换：直接 cp 覆盖会让运行中的进程映像失效，macOS 直接 SIGKILL。
mkdir -p "$HOME/.local/bin"
cp llmq "$HOME/.local/bin/.llmq.new"
chmod +x "$HOME/.local/bin/.llmq.new"
mv -f "$HOME/.local/bin/.llmq.new" "$HOME/.local/bin/llmq"
LLMQ="$HOME/.local/bin/llmq"
echo "    /Applications/$APP_NAME.app 和 ~/.local/bin/llmq"

echo "==> 2/4 清掉这台机器自己建过的 CA（如果有）"
# 集群只能有一个 CA。这台机器要是自己跑过 cluster init，
# 那套 CA 的私钥留着没用还容易混淆 —— 将来在这儿 enroll 会签出
# 谁都不认的证书，排查起来很费劲。
rm -f "$CLUSTER/ca.key" "$CLUSTER/ca.srl"

echo "==> 3/4 导入证书并配置对端"
mkdir -p "$CLUSTER"
echo "$P12_PASS" | "$LLMQ" cluster import "$NODE_NAME" ./node.p12 ./ca.crt >/dev/null
"$LLMQ" cluster trust "$SERVER_NAME" >/dev/null
"$LLMQ" cluster peer "$SERVER_NAME" "$SERVER_ADDR" >/dev/null
echo "    本机 ${NODE_NAME}，对端 $SERVER_NAME → $SERVER_ADDR"

echo "==> 4/4 自毁"
# 这个包里有证书和口令，是一次性的。装完就从 iCloud 删掉，
# 删除会同步到所有设备，不留一个长期躺在共享盘里的凭据。
D="$HOME/Library/Mobile Documents/com~apple~CloudDocs/$APP_NAME/dist"
rm -f "$D"/llmq-setup-"$NODE_NAME".tar.gz "$D"/llmq-setup-"$NODE_NAME".sha256
echo "    入职包已从 iCloud 删除"

open /Applications/"$APP_NAME".app 2>/dev/null || true

echo
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) echo "注意：~/.local/bin 不在 PATH。加一行："
     echo "  echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.zshrc && source ~/.zshrc"
     echo ;;
esac

echo "装好了。验一下（对面要先跑着 llmq cluster serve）："
echo "  llmq cluster ping $SERVER_NAME"
echo
echo "然后就能派活了："
echo "  llmq cluster dispatch $SERVER_NAME \"<任务>\" --repo <仓库别名>"
INSTALL
chmod +x "$STAGE/install.sh"

# 打包前自检。`$VAR` 后面紧跟中文字符时，非 UTF-8 locale 下的 bash 会把
# 高位字节当成标识符的一部分，去找一个叫 `NODE_NAME，` 的变量 ——
# 配上 set -u 就是 "unbound variable"，而且只在**对方那台机器**上炸，
# 本机 locale 正常，测不出来。踩过一次，所以加这道门。
python3 - "$STAGE/install.sh" <<'LINT'
import re, sys
s = open(sys.argv[1], encoding="utf-8").read()
bad = [(s[:m.start()].count("\n") + 1, m.group(1))
       for m in re.finditer(r"\$([A-Za-z_][A-Za-z0-9_]*)(?=[^\x00-\x7f])", s)]
for ln, v in bad:
    print(f"  install.sh 第 {ln} 行：${v} 后面紧跟非 ASCII，要写成 ${{{v}}}")
sys.exit(1 if bad else 0)
LINT
if [ $? -ne 0 ]; then
  echo "==> 自检没过，不打包"
  exit 1
fi

echo "==> 打包"
mkdir -p "$ICLOUD"
TAR="$ICLOUD/$BUNDLE.tar.gz"
tar --no-mac-metadata -czf "$TAR" -C "$(dirname "$STAGE")" "$BUNDLE"
chmod 600 "$TAR"
rm -rf "$(dirname "$STAGE")"

SHA=$(shasum -a 256 "$TAR" | awk '{print $1}')

echo
echo "==> 入职包已就绪（$(du -h "$TAR" | awk '{print $1}')）"
echo "    别忘了这台机器上要跑着：llmq cluster serve"
echo
echo "在 $NODE 上贴这一条，装完直接就能互相派活："
echo
cat <<CMD
D=~/Library/Mobile\\ Documents/com~apple~CloudDocs/LLMQuotaBar/dist; F=$BUNDLE.tar.gz; ( set -e; [ -d "\$D" ] || { echo "✗ iCloud 里没有这个目录：\$D"; echo "  这台机器登的是同一个 Apple ID 吗？iCloud 云盘开了吗？"; exit 1; }; echo "等 iCloud 把包同步过来…"; brctl download "\$D" 2>/dev/null || true; for i in \$(seq 45); do [ -f "\$D/\$F" ] && break; printf '.'; sleep 2; done; echo; [ -f "\$D/\$F" ] || { echo "✗ 等了 90 秒还没下来。目录里现在是："; ls -a "\$D" | sed 's/^/    /'; echo "  改用隔空投送更快。"; exit 1; }; head -c1 "\$D/\$F" >/dev/null 2>&1 || { echo "✗ 文件在，但读不了（Operation not permitted）"; echo "  这是 macOS 的 TCC：iCloud 云盘是受保护目录，终端还没拿到访问权。"; echo "  系统设置 → 隐私与安全性 → 完全磁盘访问权限 → 把「终端」打开，然后重开终端再跑。"; echo "  这个权限本来也必须给 —— llmq 要往 iCloud 写用量快照。"; echo "  不想给就改用隔空投送，落在 ~/Downloads 不受 TCC 管。"; exit 1; }; echo "$SHA  \$D/\$F" | shasum -a 256 -c - && T=\$(mktemp -d) && tar xzf "\$D/\$F" -C "\$T" && "\$T/$BUNDLE/install.sh" )
CMD
echo
echo "这条命令三件事都有兜底：目录不存在、包没同步过来、哈希对不上，"
echo "都会明确报错退出，不会像裸 until 循环那样一声不响地转下去。"
echo "整条跑在子 shell 里，失败也不会把你的终端关掉。"
echo
echo "同步太慢的话，直接隔空投送这个文件更快："
echo "  $TAR"
echo "然后在那台机器上：tar xzf ~/Downloads/$BUNDLE.tar.gz -C \$(mktemp -d)/ 再跑里面的 install.sh"
echo
