import XCTest
@testable import LLMQuotaCore

/// **驱动脚本不许给 zsh 的特殊变量赋值。**
///
/// ## 这条对应的真实故障
///
/// 媒体驱动里有一句 `path="${parts[1]-}"`。而 zsh 里 **`path` 是绑死
/// `PATH` 的特殊数组** —— 这一句会把 `PATH` 直接改成那个图片路径。
/// 实测 PATH 从 700 字符变成 7 字符，之后所有裸命令
/// （`file`、`sips`、`awk`…）全部 command not found。
///
/// **它不报错、不退出，只是静静地全失败**，所以藏了很久：
///
/// - 驱动开头「三条铁律」里写的「同一个 zsh 里 `$(…|awk…)` 第一次成功、
///   之后每次 command not found」就是它。当时只记了现象、没查出根因，
///   于是用「只用内建 + 绝对路径」绕过去了。
/// - 驱动第一行 `echo "# PATH=$PATH"` 打的是**赋值之前**的 PATH，
///   日志里永远好看 —— 现场证据反而在替它打掩护。
/// - 2026-08-20 加 PNG 格式校验时才撞出来：那段校验用了裸 `file`/`sips`，
///   于是永远走「转换失败」分支。**比不加校验更糟 —— 它会谎报
///   「校验过了但失败」**，把一个没做的检查显示成一个做了没通过的检查。
///
/// 抽出真驱动跑对照实验（假 mmx 吐 JPEG 到 `.png`）：
///
/// | 版本 | 输出 | 买家拿到的 |
/// |---|---|---|
/// | `path` + 裸命令（改动前） | `WARN … 且转换失败` | **JPEG** |
/// | `dest` + 裸命令 | `FIX … 已转真 PNG` | PNG |
/// | `dest` + 绝对路径（现在） | `FIX … 已转真 PNG` | PNG |
///
/// 所以改名是治根那一刀，绝对路径只是保险。
///
/// ## 为什么用静态检查而不是跑一遍
///
/// 真跑要有 mmx、要烧额度、要联网。而这个 bug 的**形状**是纯文本的：
/// 「驱动里出现了 `<特殊变量>=`」。形状能静态查，就不该留给运行时。
final class DriverShellHygieneTests: XCTestCase {

    /// zsh 里赋值会产生远距离副作用的参数。
    ///
    /// 只列**数组/标量绑定**那几个（改一个动另一个）和会改变解析行为的。
    /// 全列一遍没有意义 —— 这里要拦的是「看起来像普通局部变量、
    /// 实则是全局开关」的那一类。
    private static let dangerous = [
        "path",      // ← 就是它，绑 PATH
        "cdpath", "fpath", "manpath", "infopath",
        "PATH",      // 直接写 PATH= 也不行（驱动要的是 export 前置，不是覆盖）
        "IFS",       // 改了之后所有分词行为都变
        "argv", "status", "options", "module_path",
    ]

    /// 所有内联 zsh 驱动。新增执行器时加进来。
    private func drivers() -> [(name: String, script: String)] {
        var out: [(String, String)] = []
        for r in [MiniMaxMediaRunner() as AgentRunner,
                  MiniMaxReviewRunner() as AgentRunner] {
            let c = r.command(prompt: "IMG a.png :: x", cwd: "/tmp")
            guard c.launchPath.hasSuffix("zsh"), c.args.count >= 2 else { continue }
            out.append((String(describing: type(of: r)), c.args[1]))
        }
        return out
    }

    func testDriversNeverAssignToZshSpecialVariables() {
        let drivers = self.drivers()
        XCTAssertFalse(drivers.isEmpty, "一个驱动都没取到 —— 这个测试就白跑了")
        for (name, script) in drivers {
            for line in script.split(separator: "\n", omittingEmptySubsequences: false) {
                let s = line.trimmingCharacters(in: .whitespaces)
                guard !s.hasPrefix("#") else { continue }   // 注释里提它是允许的
                for v in Self.dangerous {
                    // `export PATH=…` 是有意的前置，不算；裸 `PATH=` 才算。
                    if s.hasPrefix("export ") { continue }
                    XCTAssertFalse(
                        s.hasPrefix(v + "=") || s.contains("; " + v + "=")
                            || s.contains("local " + v + "="),
                        "\(name) 给 zsh 特殊变量 `\(v)` 赋值了 —— "
                        + "这会静默改掉全局行为（`path=` 直接毁掉 PATH，"
                        + "之后所有裸命令 command not found，不报错）：\(s)")
                }
            }
        }
    }

    /// **校验用的外部命令必须写绝对路径。**
    ///
    /// 上面那条拦的是根因，这条拦的是「万一根因又被引进来」时的爆炸半径。
    /// 驱动已有的约定就是这样（`/bin/mkdir`、`/bin/mv`、`/bin/rm`），
    /// 新加的检查跟上同一套。
    func testDriverExternalCommandsUseAbsolutePaths() {
        for (name, script) in drivers() {
            for cmd in ["file", "sips", "mkdir", "mv", "rm", "awk", "grep"] {
                for line in script.split(separator: "\n") {
                    let s = line.trimmingCharacters(in: .whitespaces)
                    guard !s.hasPrefix("#") else { continue }
                    // 命令位置：行首、`(`、`|`、`&&` 之后，或命令替换里
                    let pattern = "(^|[;(|&]\\s*|\\$\\(\\s*)\(cmd)\\s"
                    guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
                    let r = NSRange(s.startIndex..., in: s)
                    XCTAssertEqual(
                        re.numberOfMatches(in: s, range: r), 0,
                        "\(name) 用了裸命令 `\(cmd)` —— PATH 一旦被改掉就"
                        + "静默失败，跟 /bin/mkdir 一样写绝对路径：\(s)")
                }
            }
        }
    }
}
