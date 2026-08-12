import Foundation

/// 把 Dashboard 渲染成一张「数字员工看板」HTML。
///
/// 为什么不用菜单栏那个弹窗：弹窗只有 380pt 宽，适合"瞄一眼最紧急的那条"，
/// 不适合横向对比九个平台谁在干活、谁在空转。这两个界面回答的是不同的问题。
///
/// 页面自带数据（把 Dashboard 的 JSON 内联进去），不发任何网络请求，
/// 所以离线能看、能直接丢给别人看。
public enum DashboardHTML {

    /// - Parameter standalone: true 生成完整 HTML 文档（本地 open 用）；
    ///   false 只生成片段（style + 内容 + script），供外部套壳。
    /// - Parameter include3D: 关掉可以省下 500KB 的 three.js，页面退回纯 2D。
    public static func render(
        _ dashboard: Dashboard, standalone: Bool = true, include3D: Bool = true
    ) throws -> String {
        let data = try SnapshotCoding.encoder().encode(dashboard)
        let json = String(decoding: data, as: UTF8.self)
        var body = template.replacingOccurrences(of: "__DASHBOARD_DATA__", with: json)

        // 3D 是增强，不是前提：拿不到资源就静默退回 2D，页面照常可用。
        var scene = ""
        if include3D, let three = resourceText("three.inline.js"),
           let office = resourceText("office3d.js") {
            scene = "<script>\n" + three + "\n</script>\n<script>\n" + office + "\n</script>"
        }
        body = body.replacingOccurrences(of: "__SCENE_SCRIPTS__", with: scene)

        guard standalone else { return body }
        return """
        <!doctype html>
        <html lang="zh-CN">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>数字员工看板 · LLM 额度</title>
        </head>
        <body>
        \(body)
        </body>
        </html>
        """
    }

    /// 找出资源文件。
    ///
    /// 为什么要试这么多路径：SwiftPM 在 macOS 上产出的是**扁平** bundle
    /// （`X.bundle/Resources/foo.js`），但 Foundation 的 `Bundle.resourceURL`
    /// 按 macOS 惯例去找 `X.bundle/Contents/Resources`，直接扑空。
    /// 另外这个 CLI 会被单独拷到 ~/.local/bin，那时 bundle 根本不在旁边，
    /// 所以还得能从已安装的 .app 里、或开发时的源码树里找。
    /// 候选资源包。**不碰 `Bundle.module`。**
    ///
    /// 它是 SwiftPM 生成的 `static let`，找不到资源包时直接 `fatalError`，
    /// 捕获不了。而下面那一串兜底路径，写的正是「资源包不在旁边」的情形 ——
    /// 于是为那种情况准备的代码，**在那种情况下一行也执行不到**，进程先崩了。
    ///
    /// 更糟的是 `llmq doctor` 会调 `resourceDiagnostics()`：一个专门用来
    /// 报告「资源找没找到」的诊断，自己死在了资源缺失上。表现是整条命令
    /// 一个字都不打印就崩，看起来像安装坏了，而不是像少了个文件。
    ///
    /// `Bundle(url:)` 找不到只返回 nil，所以自己按路径找。
    static func candidateBundles() -> [Bundle] {
        let name = "LLMQuotaBar_LLMQuotaCore.bundle"
        let exeDir = URL(fileURLWithPath: CommandLine.arguments[0])
            .resolvingSymlinksInPath().deletingLastPathComponent()
        var urls = [
            exeDir.appendingPathComponent(name),
            // .app 里：可执行文件在 Contents/MacOS，资源在 Contents/Resources
            exeDir.deletingLastPathComponent().appendingPathComponent("Resources/\(name)"),
            Bundle.main.bundleURL.appendingPathComponent(name),
        ]
        if let r = Bundle.main.resourceURL { urls.append(r.appendingPathComponent(name)) }
        return urls.compactMap {
            FileManager.default.fileExists(atPath: $0.path) ? Bundle(url: $0) : nil
        }
    }

    public static func resourceSearchPaths(_ file: String) -> [URL] {
        var out: [URL] = []
        func add(_ u: URL?) { if let u { out.append(u) } }

        for bundle in candidateBundles() {
            add(bundle.url(forResource: file, withExtension: nil, subdirectory: "Resources"))
            add(bundle.url(forResource: file, withExtension: nil))
            add(bundle.bundleURL.appendingPathComponent("Resources/\(file)"))
            add(bundle.resourceURL?.appendingPathComponent(file))
        }

        // 一个候选都没命中时，**仍然要给出试过哪些路径** ——
        // 一份空的诊断和「没装」长得一模一样。
        let exeDir = URL(fileURLWithPath: CommandLine.arguments[0])
            .resolvingSymlinksInPath().deletingLastPathComponent()
        let bundleName = "LLMQuotaBar_LLMQuotaCore.bundle"
        add(exeDir.appendingPathComponent("\(bundleName)/Resources/\(file)"))
        add(exeDir.deletingLastPathComponent()
            .appendingPathComponent("Resources/\(bundleName)/Resources/\(file)"))

        return out
    }

    private static func resourceText(_ file: String) -> String? {
        for url in resourceSearchPaths(file) {
            if let s = try? String(contentsOf: url, encoding: .utf8), !s.isEmpty {
                return s
            }
        }
        return nil
    }

    /// 给 `llmq doctor` 用：报告每个 3D 资源是从哪儿找到的、或者为什么没找到。
    public static func resourceDiagnostics() -> [(file: String, found: URL?, tried: [URL])] {
        ["three.inline.js", "office3d.js"].map { file in
            let paths = resourceSearchPaths(file)
            let hit = paths.first { FileManager.default.fileExists(atPath: $0.path) }
            return (file, hit, paths)
        }
    }

    // MARK: - Template

    private static let template = """
    <style>
    /* 配色以青灰为中性偏向，主色靛青，语义色单独留给"在岗/闲置/耗尽"三种状态 —— */
    /* 主色和状态色分开，状态才能一眼读出来而不跟品牌色打架。 */
    :root {
      --paper:      #E9EDEC;
      --paper-card: #F4F6F5;
      --paper-sunk: #DDE3E2;
      --ink:        #10171A;
      --ink-soft:   #48565B;
      --ink-faint:  #7C8B90;
      --rule:       #C8D2D1;
      --accent:     #2E6F7E;
      --accent-dim: #7FA9B2;
      --good:       #3E8A5C;
      --warn:       #C08326;
      --crit:       #B4483C;
      --idle:       #8A9599;

      --serif: "Songti SC", "STSong", "Source Han Serif SC", "Noto Serif CJK SC", Georgia, serif;
      --sans:  "PingFang SC", "Hiragino Sans GB", "Microsoft YaHei", -apple-system, sans-serif;
      --mono:  "SF Mono", ui-monospace, Menlo, Consolas, monospace;
    }

    @media (prefers-color-scheme: dark) {
      :root {
        --paper:      #0E1417;
        --paper-card: #161F23;
        --paper-sunk: #0A0F11;
        --ink:        #E4EAE9;
        --ink-soft:   #A2B0B4;
        --ink-faint:  #6B7A7F;
        --rule:       #253238;
        --accent:     #6FB3C2;
        --accent-dim: #35606C;
        --good:       #5FB080;
        --warn:       #D9A24A;
        --crit:       #D96A5C;
        --idle:       #5E6B70;
      }
    }
    /* 主题切换必须能双向压过媒体查询，所以两个方向都要显式声明一遍。 */
    :root[data-theme="dark"] {
      --paper:#0E1417; --paper-card:#161F23; --paper-sunk:#0A0F11;
      --ink:#E4EAE9; --ink-soft:#A2B0B4; --ink-faint:#6B7A7F; --rule:#253238;
      --accent:#6FB3C2; --accent-dim:#35606C;
      --good:#5FB080; --warn:#D9A24A; --crit:#D96A5C; --idle:#5E6B70;
    }
    :root[data-theme="light"] {
      --paper:#E9EDEC; --paper-card:#F4F6F5; --paper-sunk:#DDE3E2;
      --ink:#10171A; --ink-soft:#48565B; --ink-faint:#7C8B90; --rule:#C8D2D1;
      --accent:#2E6F7E; --accent-dim:#7FA9B2;
      --good:#3E8A5C; --warn:#C08326; --crit:#B4483C; --idle:#8A9599;
    }

    * { box-sizing: border-box; }

    .board {
      background: var(--paper);
      color: var(--ink);
      font-family: var(--sans);
      font-size: 15px;
      line-height: 1.6;
      padding: 32px 28px 56px;
      display: flex;
      flex-direction: column;
      gap: 34px;
      max-width: 1180px;
      margin: 0 auto;
      font-variant-numeric: tabular-nums;
    }

    .masthead { display: flex; flex-direction: column; gap: 10px; }
    /* 团队形象有 62px 高，跟 baseline 对齐会把右侧元信息顶歪，改成底对齐。 */
    .masthead-top {
      display: flex; align-items: flex-end; justify-content: space-between;
      gap: 18px; flex-wrap: wrap;
      border-bottom: 2px solid var(--ink); padding-bottom: 12px;
    }
    .masthead-title { display: flex; align-items: center; gap: 14px; }
    .masthead h1 {
      font-family: var(--serif);
      font-size: 34px; font-weight: 600; margin: 0;
      letter-spacing: 0.04em; text-wrap: balance;
    }
    .team-mood { font-size: 12px; color: var(--ink-soft); margin-top: 2px; }
    .masthead .meta {
      font-family: var(--mono); font-size: 12px; color: var(--ink-faint);
      display: flex; gap: 16px; flex-wrap: wrap;
    }

    .label {
      font-size: 11px; letter-spacing: 0.14em; text-transform: uppercase;
      color: var(--ink-faint); font-weight: 600;
    }

    /* 工位实况 */
    .office {
      position: relative; height: 300px; overflow: hidden;
      border: 1px solid var(--rule); background: var(--paper-sunk);
    }
    .office-label {
      position: absolute; transform: translate(-50%, 6px);
      font-family: var(--mono); font-size: 11px; color: var(--ink-soft);
      pointer-events: none; white-space: nowrap;
    }
    .office-note { margin-top: 8px; font-size: 11px; color: var(--ink-faint); }
    .office-fallback {
      display: flex; align-items: center; justify-content: center;
      height: 100%; color: var(--ink-faint); font-size: 12px; padding: 0 20px;
      text-align: center;
    }

    /* 总览四格 */
    .overview { display: grid; grid-template-columns: repeat(4, 1fr); gap: 1px; background: var(--rule); border: 1px solid var(--rule); }
    .tile { background: var(--paper-card); padding: 16px 18px; display: flex; flex-direction: column; gap: 5px; }
    .tile .num { font-family: var(--mono); font-size: 27px; font-weight: 600; line-height: 1.1; }
    .tile .cap { font-size: 12px; color: var(--ink-soft); }
    .tile.is-crit .num { color: var(--crit); }
    .tile.is-warn .num { color: var(--warn); }

    /* 工作量分配条 */
    .alloc-bar { display: flex; height: 34px; border: 1px solid var(--rule); overflow: hidden; }
    .alloc-seg { position: relative; min-width: 2px; transition: none; }
    .alloc-seg span {
      position: absolute; inset: 0; display: flex; align-items: center; justify-content: center;
      font-size: 11px; font-family: var(--mono); color: #fff; mix-blend-mode: normal;
      white-space: nowrap; overflow: hidden;
    }
    .alloc-legend { display: flex; flex-wrap: wrap; gap: 14px; margin-top: 10px; font-size: 12px; color: var(--ink-soft); }
    .alloc-legend i { width: 10px; height: 10px; display: inline-block; margin-right: 5px; }

    /* 员工卡 */
    .roster { display: grid; grid-template-columns: repeat(auto-fill, minmax(310px, 1fr)); gap: 14px; }
    .staff {
      background: var(--paper-card);
      border: 1px solid var(--rule);
      border-left: 4px solid var(--idle);
      padding: 15px 17px 16px;
      display: flex; flex-direction: column; gap: 11px;
    }
    .staff.s-good { border-left-color: var(--good); }
    .staff.s-warn { border-left-color: var(--warn); }
    .staff.s-crit { border-left-color: var(--crit); }
    .staff.s-idle { border-left-color: var(--idle); opacity: 0.82; }

    .staff-head { display: flex; align-items: center; justify-content: space-between; gap: 10px; }
    .staff-id { display: flex; align-items: center; gap: 11px; min-width: 0; }
    .staff-name { font-family: var(--serif); font-size: 21px; font-weight: 600; letter-spacing: 0.03em; }

    /* 工牌头像。表情承担和左侧色条一样的信息 —— 状态要在读文字之前就到眼睛里。 */
    .mascot { flex: none; display: block; }
    .mascot .head { fill: var(--accent); }
    .mascot .plate { fill: var(--paper-card); }
    .mascot .ink { fill: var(--ink); }
    .mascot .clip { fill: var(--ink-faint); }
    .mascot .stroke { stroke: var(--ink); stroke-width: 2; stroke-linecap: round; fill: none; }
    .mascot .accent { fill: var(--accent); }

    /* 在岗：眨眼 + 屏幕上有跑动的活动点。 */
    .m-working .eyelid { animation: blink 5.2s infinite; transform-origin: center; }
    .m-working .busydot { animation: busy 1.4s infinite; }
    .m-working .busydot:nth-of-type(2) { animation-delay: 0.18s; }
    .m-working .busydot:nth-of-type(3) { animation-delay: 0.36s; }
    /* 超负荷：额头冒汗，汗珠往下掉。 */
    .m-strained .sweat { animation: drip 2.1s infinite; }
    /* 打盹和没上岗：zzz 往上飘。 */
    .m-dozing .zzz, .m-asleep .zzz { animation: float 3.4s infinite; }

    @keyframes blink { 0%,92%,100% { transform: scaleY(0); } 95% { transform: scaleY(1); } }
    @keyframes busy  { 0%,100% { opacity: 0.22; } 50% { opacity: 1; } }
    @keyframes drip  { 0% { opacity: 0; transform: translateY(-2px); }
                       35% { opacity: 1; } 100% { opacity: 0; transform: translateY(5px); } }
    @keyframes float { 0% { opacity: 0; transform: translate(0,2px) scale(0.85); }
                       40% { opacity: 1; } 100% { opacity: 0; transform: translate(3px,-6px) scale(1.1); } }

    /* 动画只是锦上添花，静态形态本身必须已经能读出状态。 */
    @media (prefers-reduced-motion: reduce) {
      .mascot * { animation: none !important; }
      .m-working .eyelid { transform: scaleY(0); }
    }
    .pill {
      font-size: 11px; padding: 2px 8px; border-radius: 2px; white-space: nowrap;
      border: 1px solid currentColor; font-weight: 600;
    }
    .pill.s-good { color: var(--good); }
    .pill.s-warn { color: var(--warn); }
    .pill.s-crit { color: var(--crit); }
    .pill.s-idle { color: var(--idle); }

    .staff-figures { display: flex; gap: 20px; }
    .fig { display: flex; flex-direction: column; }
    .fig b { font-family: var(--mono); font-size: 19px; font-weight: 600; }
    .fig span { font-size: 11px; color: var(--ink-faint); }

    .meter { display: flex; flex-direction: column; gap: 4px; }
    .meter-track { height: 7px; background: var(--paper-sunk); position: relative; overflow: hidden; }
    .meter-fill { height: 100%; background: var(--accent); }
    .meter-fill.s-good { background: var(--good); }
    .meter-fill.s-warn { background: var(--warn); }
    .meter-fill.s-crit { background: var(--crit); }
    .meter-cap { display: flex; justify-content: space-between; font-size: 11px; color: var(--ink-soft); gap: 8px; }
    .meter-cap .mono { font-family: var(--mono); }

    .staff-foot { font-size: 11px; color: var(--ink-faint); display: flex; flex-direction: column; gap: 3px; border-top: 1px solid var(--rule); padding-top: 9px; }
    .skills { font-family: var(--mono); word-break: break-all; }

    /* 影响分析 */
    .findings { display: flex; flex-direction: column; gap: 1px; background: var(--rule); border: 1px solid var(--rule); }
    .finding { background: var(--paper-card); padding: 14px 17px; display: flex; gap: 13px; align-items: flex-start; }
    .finding .mark { font-family: var(--mono); font-size: 12px; font-weight: 700; padding-top: 2px; white-space: nowrap; }
    .finding.f-crit .mark { color: var(--crit); }
    .finding.f-warn .mark { color: var(--warn); }
    .finding.f-good .mark { color: var(--good); }
    .finding.f-info .mark { color: var(--accent); }
    .finding-body h3 { margin: 0 0 3px; font-size: 15px; font-weight: 600; }
    .finding-body p { margin: 0; font-size: 13px; color: var(--ink-soft); }

    .empty { color: var(--ink-faint); font-size: 13px; padding: 14px 17px; background: var(--paper-card); border: 1px solid var(--rule); }

    footer { font-size: 11px; color: var(--ink-faint); border-top: 1px solid var(--rule); padding-top: 12px; font-family: var(--mono); }

    @media (max-width: 760px) {
      .overview { grid-template-columns: repeat(2, 1fr); }
      .board { padding: 22px 16px 40px; }
      .masthead h1 { font-size: 27px; }
    }
    </style>

    <div class="board">
      <header class="masthead">
        <div class="masthead-top">
          <div class="masthead-title">
            <span id="teamMascot"></span>
            <div>
              <h1>数字员工看板</h1>
              <div class="team-mood" id="teamMood"></div>
            </div>
          </div>
          <div class="meta" id="meta"></div>
        </div>
      </header>

      <section>
        <div class="label">工位实况</div>
        <div class="office" id="office"></div>
        <div class="office-note" id="officeNote"></div>
      </section>

      <section>
        <div class="label">团队概况</div>
        <div class="overview" id="overview"></div>
      </section>

      <section>
        <div class="label">工作量分配 · 最近 30 天</div>
        <div class="alloc-bar" id="allocBar"></div>
        <div class="alloc-legend" id="allocLegend"></div>
      </section>

      <section>
        <div class="label">花名册</div>
        <div class="roster" id="roster"></div>
      </section>

      <section>
        <div class="label">影响分析</div>
        <div id="findings"></div>
      </section>

      <footer id="footer"></footer>
    </div>

    __SCENE_SCRIPTS__

    <script>
    (function () {
      var DATA = __DASHBOARD_DATA__;

      var NAMES = {
        claude: "Claude", codex: "Codex", gemini: "Gemini", qwen: "Qwen",
        kimi: "Kimi", glm: "GLM", minimax: "MiniMax", deepseek: "DeepSeek",
        volcark: "火山方舟"
      };
      // 分配条的颜色只用于区分身份，不承载状态语义 —— 状态靠卡片左侧色条和徽章表达。
      var HUES = {
        claude: "#2E6F7E", codex: "#5C7A52", gemini: "#7A6096", qwen: "#B07B3E",
        kimi: "#9C5566", glm: "#3F7D8C", minimax: "#6E6A9B", deepseek: "#4A7C6E",
        volcark: "#A2663F"
      };

      function compact(n) {
        n = n || 0;
        if (n < 1000) return String(Math.round(n));
        if (n < 1e6) return (n / 1e3).toFixed(1) + "K";
        if (n < 1e9) return (n / 1e6).toFixed(1) + "M";
        return (n / 1e9).toFixed(1) + "B";
      }
      function pct(x, digits) { return (x * 100).toFixed(digits === undefined ? 0 : digits) + "%"; }

      function since(iso, now) {
        if (!iso) return "从未";
        var d = (now - new Date(iso)) / 1000;
        if (d < 90) return "刚刚";
        if (d < 3600) return Math.round(d / 60) + " 分钟前";
        if (d < 86400) return Math.round(d / 3600) + " 小时前";
        return Math.round(d / 86400) + " 天前";
      }
      function until(iso, now) {
        if (!iso) return null;
        var d = (new Date(iso) - now) / 1000;
        if (d <= 0) return null;
        if (d < 3600) return Math.round(d / 60) + " 分钟";
        if (d < 86400) return Math.round(d / 3600) + " 小时";
        return Math.round(d / 86400) + " 天";
      }

      var now = new Date(DATA.generatedAt);

      // 只有"装了的"才算团队成员。压根没装的平台不进花名册 —— 它们不是员工，是还没招。
      var staff = DATA.reports.filter(function (r) { return r.detected || r.installed; });
      var working = staff.filter(function (r) { return r.detected; });
      var totalReq = working.reduce(function (s, r) { return s + r.last30dRequests; }, 0);
      var totalTok = working.reduce(function (s, r) { return s + r.last30dBillableTokens; }, 0);

      function worstHealth(r) {
        var order = { exhausted: 5, atRisk: 4, wasting: 3, idle: 2, unconfigured: 1, healthy: 0 };
        var worst = null;
        (r.statuses || []).forEach(function (s) {
          if (!worst || order[s.health] > order[worst]) worst = s.health;
        });
        return worst;
      }

      // 状态判定的顺序有讲究：先看"在不在岗"，再看"岗上干得怎么样"。
      // face 决定工牌头像的表情，和 cls 分开是因为"耗尽"和"超负荷"同为红色但神情不同。
      function classify(r) {
        if (!r.detected) return { key: "idle", pill: "在编未上岗", cls: "s-idle", face: "asleep" };
        var h = worstHealth(r);
        if (h === "exhausted") return { key: "crit", pill: "产能耗尽", cls: "s-crit", face: "drained" };
        if (h === "atRisk") return { key: "crit", pill: "超负荷", cls: "s-crit", face: "strained" };
        if (h === "wasting") return { key: "warn", pill: "产能闲置", cls: "s-warn", face: "dozing" };
        if (r.last30dRequests === 0) return { key: "idle", pill: "无产出", cls: "s-idle", face: "dozing" };
        return { key: "good", pill: "在岗", cls: "s-good", face: "working" };
      }

      // 工牌头像。画成显示器造型的小人：上面有夹子，脸是一块屏。
      // 用平涂两色、不加渐变，跟整张看板的印刷感保持一致。
      function mascot(platform, face, size) {
        // 团队形象不借用任何平台的身份色，用主色，并且要跟随明暗主题 ——
        // 所以它靠 CSS 变量上色，平台头像靠内联 style（内联 style 会盖过 CSS 规则）。
        var isTeam = platform === "__team__";
        var dim = face === "asleep";
        var parts = [];

        // 工牌夹 + 头 + 面板
        parts.push('<rect x="20" y="1" width="8" height="5" rx="1.5" class="clip"/>');
        parts.push('<rect x="5" y="6" width="38" height="34" rx="7" class="head"' +
                   (isTeam ? '' : ' style="fill:' + (HUES[platform] || "#666") + '"') +
                   ' opacity="' + (dim ? 0.4 : 1) + '"/>');
        parts.push('<rect x="9.5" y="10.5" width="29" height="21" rx="3.5" class="plate"/>');

        // 眼睛：每种状态一副，光看静态形状就能区分。
        if (face === "drained") {
          // 耗尽：两只叉眼
          parts.push('<path class="stroke" d="M15 17l5 5M20 17l-5 5"/>');
          parts.push('<path class="stroke" d="M28 17l5 5M33 17l-5 5"/>');
        } else if (face === "strained") {
          // 超负荷：瞪圆的眼睛
          parts.push('<circle cx="17.5" cy="19.5" r="4" class="plate" stroke="currentColor"/>');
          parts.push('<circle cx="17.5" cy="20" r="2.2" class="ink"/>');
          parts.push('<circle cx="30.5" cy="19.5" r="4" class="plate" stroke="currentColor"/>');
          parts.push('<circle cx="30.5" cy="20" r="2.2" class="ink"/>');
        } else if (face === "dozing" || face === "asleep") {
          // 打盹/没上岗：眯着的半月眼
          parts.push('<path class="stroke" d="M13.5 20q4 3.4 8 0"/>');
          parts.push('<path class="stroke" d="M26.5 20q4 3.4 8 0"/>');
        } else {
          // 在岗：实心圆眼 + 一层会眨的眼睑
          parts.push('<circle cx="17.5" cy="19.5" r="2.6" class="ink"/>');
          parts.push('<circle cx="30.5" cy="19.5" r="2.6" class="ink"/>');
          parts.push('<rect class="ink eyelid" x="14.5" y="16.5" width="6" height="6" rx="1"/>');
          parts.push('<rect class="ink eyelid" x="27.5" y="16.5" width="6" height="6" rx="1"/>');
        }

        // 嘴
        if (face === "working") parts.push('<path class="stroke" d="M20 26.5q4 3 8 0"/>');
        else if (face === "strained") parts.push('<path class="stroke" d="M20 27.5q4 -3 8 0"/>');
        else if (face === "drained") parts.push('<path class="stroke" d="M20 27h8"/>');
        else parts.push('<path class="stroke" d="M22 27h4"/>');

        // 配件：在岗有活动指示灯，超负荷冒汗，打盹飘 zzz
        if (face === "working") {
          for (var i = 0; i < 3; i++) {
            parts.push('<circle class="busydot accent" cx="' + (19 + i * 5) + '" cy="35.5" r="1.7"/>');
          }
        } else if (face === "strained") {
          parts.push('<path class="sweat" d="M39 12c1.6 2.2 2.4 3.4 2.4 4.4a2.4 2.4 0 1 1-4.8 0c0-1 .8-2.2 2.4-4.4z" fill="#5B9BD5"/>');
        } else if (face === "dozing" || face === "asleep") {
          parts.push('<text class="zzz ink" x="38" y="12" font-size="9" font-weight="700">z</text>');
          parts.push('<text class="zzz ink" x="43" y="7" font-size="6.5" font-weight="700">z</text>');
        }

        return '<svg class="mascot m-' + face + '" width="' + size + '" height="' + size +
               '" viewBox="0 0 48 44" aria-hidden="true">' + parts.join("") + '</svg>';
      }

      // ---- 团队形象：取全队最需要被看见的那个状态，而不是取平均。
      // 一个人烧穿了额度，整队的表情就该是那个人的表情。
      (function () {
        var faces = staff.map(function (r) { return classify(r).face; });
        var rank = ["drained", "strained", "dozing", "asleep", "working"];
        var moods = {
          drained:  "有成员产能已经烧穿，工作得往别处转",
          strained: "有成员逼近上限，随时会失败",
          dozing:   "有产能正在闲置，再不派活就作废了",
          asleep:   "有成员在编未上岗",
          working:  "全员在岗，产能分配正常"
        };
        var worst = "working";
        for (var i = 0; i < rank.length; i++) {
          if (faces.indexOf(rank[i]) >= 0) { worst = rank[i]; break; }
        }
        // 团队形象用主色，不借用某个平台的身份色。
        var el = document.getElementById("teamMascot");
        el.innerHTML = mascot("__team__", worst, 62);
        document.getElementById("teamMood").textContent = moods[worst];
      })();

      // ---- 顶部元信息
      document.getElementById("meta").innerHTML =
        '<span>' + DATA.machines.length + ' 台设备</span>' +
        '<span>' + staff.length + ' 名在编</span>' +
        '<span>数据截至 ' + now.toLocaleString("zh-CN", { hour12: false }) + '</span>';

      // ---- 总览
      var exhausted = working.filter(function (r) {
        var h = worstHealth(r); return h === "exhausted" || h === "atRisk";
      });
      var idlers = staff.filter(function (r) { return !r.detected; });
      var wasting = working.filter(function (r) { return worstHealth(r) === "wasting"; });

      var tiles = [
        { num: compact(totalTok), cap: "30 天总产出 token", cls: "" },
        { num: String(working.length) + " / " + String(staff.length), cap: "实际在岗 / 在编", cls: "" },
        { num: String(exhausted.length), cap: "产能耗尽或超负荷", cls: exhausted.length ? "is-crit" : "" },
        { num: String(idlers.length + wasting.length), cap: "闲置或产能浪费", cls: (idlers.length + wasting.length) ? "is-warn" : "" }
      ];
      document.getElementById("overview").innerHTML = tiles.map(function (t) {
        return '<div class="tile ' + t.cls + '"><div class="num">' + t.num + '</div><div class="cap">' + t.cap + '</div></div>';
      }).join("");

      // ---- 工作量分配
      var ranked = working.slice().sort(function (a, b) { return b.last30dBillableTokens - a.last30dBillableTokens; });
      var barEl = document.getElementById("allocBar");
      var legEl = document.getElementById("allocLegend");
      if (totalTok > 0) {
        barEl.innerHTML = ranked.map(function (r) {
          var share = r.last30dBillableTokens / totalTok;
          var hue = HUES[r.platform] || "#666";
          var label = share > 0.12 ? (NAMES[r.platform] + " " + pct(share)) : "";
          return '<div class="alloc-seg" style="flex:' + Math.max(share, 0.002) +
                 ';background:' + hue + '" title="' + NAMES[r.platform] + " " + pct(share, 1) + '">' +
                 '<span>' + label + '</span></div>';
        }).join("");
        legEl.innerHTML = ranked.map(function (r) {
          var share = r.last30dBillableTokens / totalTok;
          return '<span><i style="background:' + (HUES[r.platform] || "#666") + '"></i>' +
                 NAMES[r.platform] + " " + pct(share, 1) + '</span>';
        }).join("");
      } else {
        barEl.style.display = "none";
        legEl.innerHTML = '<span>最近 30 天没有任何产出记录。</span>';
      }

      // ---- 花名册
      document.getElementById("roster").innerHTML = staff.map(function (r) {
        var st = classify(r);
        var share = totalTok > 0 ? r.last30dBillableTokens / totalTok : 0;

        // 有上限的额度条优先展示；一条都没配就说明"编制未定"，这是默认状态，不该显示成异常。
        var quota = (r.statuses || []).filter(function (s) { return s.limit != null; })[0];
        var meter = "";
        if (quota) {
          var f = Math.min(1, Math.max(0, quota.usedFraction || 0));
          var cls = quota.health === "exhausted" || quota.health === "atRisk" ? "s-crit"
                  : quota.health === "wasting" ? "s-warn" : "s-good";
          var reset = until(quota.resetsAt, now);
          meter =
            '<div class="meter">' +
              '<div class="meter-track"><div class="meter-fill ' + cls + '" style="width:' + (f * 100) + '%"></div></div>' +
              '<div class="meter-cap"><span>' + quota.label + '额度 <span class="mono">' + pct(f) + '</span>' +
              (quota.isOfficial ? " · 平台直报" : "") + '</span>' +
              '<span class="mono">' + (reset ? reset + "后重置" : "") + '</span></div>' +
            '</div>';
        } else {
          meter = '<div class="meter"><div class="meter-track"></div>' +
                  '<div class="meter-cap"><span>编制未定 · 未配额度上限</span></div></div>';
        }

        // 7 天日均 vs 30 天日均，看这个员工在爬坡还是在退场。
        var trend = "";
        if (r.last30dRequests > 0) {
          var d7 = r.last7dRequests / 7, d30 = r.last30dRequests / 30;
          if (r.last7dRequests === r.last30dRequests && r.last30dRequests > 0) trend = "新入职 · 全部产出在最近 7 天";
          else if (d30 > 0 && d7 > d30 * 1.3) trend = "产出上升 · 近 7 天日均 " + compact(d7) + " 次";
          else if (d30 > 0 && d7 < d30 * 0.5) trend = "产出下滑 · 近 7 天日均 " + compact(d7) + " 次";
          else trend = "产出平稳 · 日均 " + compact(d7) + " 次";
        }

        var models = (r.topModels || []).slice(0, 2).map(function (m) { return m.model; }).join(" · ");

        return '' +
          '<article class="staff ' + st.cls + '">' +
            '<div class="staff-head">' +
              '<span class="staff-id">' +
                mascot(r.platform, st.face, 44) +
                '<span class="staff-name">' + (NAMES[r.platform] || r.platform) + '</span>' +
              '</span>' +
              '<span class="pill ' + st.cls + '">' + st.pill + '</span>' +
            '</div>' +
            '<div class="staff-figures">' +
              '<div class="fig"><b>' + compact(r.last30dRequests) + '</b><span>30 天调用</span></div>' +
              '<div class="fig"><b>' + compact(r.last30dBillableTokens) + '</b><span>30 天 token</span></div>' +
              '<div class="fig"><b>' + pct(share, share > 0 && share < 0.01 ? 1 : 0) + '</b><span>工作量占比</span></div>' +
            '</div>' +
            meter +
            '<div class="staff-foot">' +
              (trend ? '<span>' + trend + '</span>' : '<span>最近 30 天无产出</span>') +
              (models ? '<span class="skills">' + models + '</span>' : '') +
              '<span>最近活动 ' + since(r.lastActivity, now) +
                (r.machines && r.machines.length ? " · " + r.machines.join("、") : "") + '</span>' +
            '</div>' +
          '</article>';
      }).join("");

      // ---- 影响分析：结论必须从数据里推出来，而不是写死几条套话
      var findings = [];

      if (ranked.length > 0 && totalTok > 0) {
        var top = ranked[0];
        var topShare = top.last30dBillableTokens / totalTok;
        if (topShare > 0.7) {
          findings.push({
            cls: "f-warn", mark: "依赖集中",
            title: NAMES[top.platform] + " 一个人扛了 " + pct(topShare) + " 的工作量",
            desc: "其余 " + (working.length - 1) + " 名在岗成员合计只承担 " + pct(1 - topShare) +
                  "。这名成员一旦触顶或故障，没有能接住的替补 —— 调度器应该主动把可迁移的任务分流出去。"
          });
        }
      }

      exhausted.forEach(function (r) {
        var s = (r.statuses || []).filter(function (x) {
          return x.health === "exhausted" || x.health === "atRisk";
        })[0];
        var reset = s ? until(s.resetsAt, now) : null;
        findings.push({
          cls: "f-crit", mark: "产能耗尽",
          title: NAMES[r.platform] + " 的" + (s ? s.label : "") + "额度已经用满",
          desc: (reset ? reset + "后才恢复。" : "") +
                "这段时间派给它的任务只会失败，调度器必须把它从候选里摘掉，否则会白白浪费任务重试。"
        });
      });

      wasting.forEach(function (r) {
        var s = (r.statuses || []).filter(function (x) { return x.health === "wasting"; })[0];
        var left = s && s.projectedUsedFraction != null ? Math.max(0, 1 - s.projectedUsedFraction) : null;
        var reset = s ? until(s.resetsAt, now) : null;
        findings.push({
          cls: "f-warn", mark: "产能浪费",
          title: NAMES[r.platform] + " 按当前节奏用不完这轮额度",
          desc: (left != null ? "预计到期时还剩 " + pct(left) + " 没用" : "额度明显用不满") +
                (reset ? "，" + reset + "后清零作废" : "") + "。这是最该被调度器优先填满的产能。"
        });
      });

      idlers.forEach(function (r) {
        findings.push({
          cls: "f-warn", mark: "零产出",
          title: NAMES[r.platform] + " 在编但最近 32 天没有任何产出",
          desc: "工具装了、配置也在，就是没派活" +
                (r.monthlyCost ? "，而每月 " + r.monthlyCost + " " + r.currency + " 照常在扣" : "") +
                "。要么给它派任务，要么考虑退订。"
        });
      });

      working.forEach(function (r) {
        if (r.last30dRequests > 0 && r.last7dRequests === r.last30dRequests) {
          findings.push({
            cls: "f-good", mark: "新成员",
            title: NAMES[r.platform] + " 是最近才加入的",
            desc: "全部 " + compact(r.last30dRequests) + " 次调用都发生在最近 7 天。" +
                  "历史样本还不够，调度器对它的额度推算暂时不可靠，先别把重任务压上去。"
          });
        }
      });

      var unconfigured = working.filter(function (r) {
        return (r.statuses || []).every(function (s) { return s.limit == null; });
      });
      if (unconfigured.length > 0) {
        findings.push({
          cls: "f-info", mark: "编制未定",
          title: unconfigured.length + " 名在岗成员还没配额度上限",
          desc: unconfigured.map(function (r) { return NAMES[r.platform]; }).join("、") +
                "。没有上限就算不出剩余和作废量，调度器只能按「有没有在用」粗略判断。" +
                "把各家订阅页面上的实际上限填进 plans.json，这块才能真正生效。"
        });
      }

      var fEl = document.getElementById("findings");
      if (findings.length === 0) {
        fEl.innerHTML = '<div class="empty">没有发现需要处理的问题。</div>';
      } else {
        fEl.className = "findings";
        fEl.innerHTML = findings.map(function (f) {
          return '<div class="finding ' + f.cls + '">' +
                   '<span class="mark">' + f.mark + '</span>' +
                   '<div class="finding-body"><h3>' + f.title + '</h3><p>' + f.desc + '</p></div>' +
                 '</div>';
        }).join("");
      }

      // ---- 工位实况：把状态和活跃度喂给 3D 场景
      (function () {
        var host = document.getElementById("office");
        var note = document.getElementById("officeNote");

        function fallback(msg) {
          host.innerHTML = '<div class="office-fallback">' + msg + '</div>';
          note.textContent = "";
        }
        if (!window.LLMQOffice) {
          fallback("这份看板是以纯 2D 方式生成的（llmq dashboard --no-3d）。");
          return;
        }

        // 活跃度用近 7 天日均调用量，按全队最忙的那个归一化 ——
        // 绝对值没有可比性（Claude 几千次和 Qwen 几次不是一个量级），
        // 相对忙碌程度才是"谁在拼命敲键盘"该表达的东西。
        var rates = working.map(function (r) { return r.last7dRequests / 7; });
        var peak = Math.max.apply(null, rates.concat([1]));

        var rows = staff.map(function (r) {
          var st = classify(r);
          var state = st.face === "asleep" ? "absent" : st.face;
          return {
            name: NAMES[r.platform] || r.platform,
            hue: parseInt((HUES[r.platform] || "#666666").slice(1), 16),
            state: state,
            activity: peak > 0 ? (r.last7dRequests / 7) / peak : 0
          };
        });

        var ok = window.LLMQOffice.mount(host, rows);
        if (!ok) {
          fallback("这台设备的浏览器没有可用的 WebGL，3D 工位没法渲染。下面的花名册不受影响。");
          return;
        }

        var busiest = null;
        working.forEach(function (r) {
          if (!busiest || r.last7dRequests > busiest.last7dRequests) busiest = r;
        });
        note.textContent = "敲键盘的快慢来自各平台近 7 天的真实调用频率"
          + (busiest ? "，现在手速最快的是 " + NAMES[busiest.platform] : "")
          + "。空工位表示在编未上岗，趴桌上表示额度已烧穿。";
      })();

      document.getElementById("footer").textContent =
        "由 llmq dashboard 生成 · 数据来自本机各 CLI 的会话日志，未经任何网络请求 · " +
        DATA.machines.map(function (m) { return m.machineName + (m.isStale ? "（快照较旧）" : ""); }).join(" / ");
    })();
    </script>
    """
}
