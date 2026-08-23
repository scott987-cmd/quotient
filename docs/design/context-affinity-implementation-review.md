# 实现评审：上下文连续性调度改造

> Claude，2026-08-24。评审对象：Codex 对 `docs/design/context-affinity-scheduling.md`
> 阶段 0–3a 的实现（评审时**尚未提交**，在工作区里）。
>
> 改动规模：7 个文件改动 + 4 个新文件，912 行插入 / 553 行删除。
> `Sources/LLMQuotaCore/ContextAffinityPolicy.swift`（65）、`WorkAttempt.swift`（206）、
> `Tests/LLMQuotaCoreTests/ContextAffinityTests.swift`（258）、`InvocationIdentityTests.swift`（22）。
>
> **单独成文的原因**：改动未提交，直接改那些文件会和作者互相覆盖。本文只读、不改代码。

## 零、结论先说

**这批改造质量高，方向正确，可以合入**，但下面第二节的 11 条建议先处理 ——
其中 2.1（人工 retry 被架空）和 2.9（工作区归属只凭进程起来过）是实际缺陷，
2.2 / 2.3 / 2.4 是它自己的设计文档明确要求、实现没做到的，2.5 / 2.6 / 2.7 是核心验收点缺测试。
2.8 是我自己判错后的撤回——其中两条是它自己的设计文档
明确要求、实现没做到的（措辞、泳道隔离的测试），另两条会让新加的账本在真出事时丢数据。

硬事实：

- **全量 897 条测试 0 失败**（改造前 886 条，新增 11 条）。
- **变异验证：9 个变异，7 个被测试逮到，1 个可辩护，1 个真存活。** 明细见第三节。
- 六路并行只读评审共报 40 条，34 条经反方验证，**26 条成立、8 条被驳回**；口径见第六节。
  这批测试不是摆设 —— 这是本次评审最重要的正面结论。
- 我在 scratchpad 里复制了一份仓库做变异，**没有碰作者的工作区**。
  台架自检做过（塞语法错误 → 26 个编译错误），排除假阴性。

## 一、做对了的（值得记下来，避免以后被改回去）

1. **仓库级串会话的病治好了。** 会话作用域从 `repo:<路径>|platform`
   改成 `taskID`（图内为 `graphID + capability lane`）+ `runnerID` + `machineID`
   （`GraphSession.Context.storageKey`）。同仓库两条无关任务不再接进彼此的聊天历史。
2. **「接上会话（省去重读仓库）」那句 87% 说谎的日志，源头堵住了。**
   `GraphSession.mode` 现在要求传 `sessionSupport`，不支持的 Runner 直接得到 `.fresh`，
   不再产生映射、不再打印恢复。
3. **`SessionSupport` 比设计文档多了一档 `.reportedID`**（ZCode 那种「CLI 在输出里报会话 ID」），
   并且 `testReportedSessionIDIsNeverInvented` 明确禁止凭空编造 ID。这是比设计更细的正确处理。
4. **人工停用不再吃掉自动交接名额。** `ContextAffinityPolicy` 把 `handoffCount`（所有转移）
   和 `automaticHandoffCount`（只算自动故障转移）分开，`canProceedToNext` 只看后者。
   这正是二轮 review 提的问题，解法比我建议的更干净。
5. **`WorkAttemptStore.append` 的写入实现很扎实**：`O_APPEND` + `flock(LOCK_EX)` +
   部分写循环 + `EINTR` 重试，跨进程安全。worker 和手工 `llmq` 命令同时写不会互相截断。
6. **`TaskCapabilityLane.classify` 复用 `TaskKind` 的单一判定源**，没有再犯
   「同一概念多处判定」的老毛病；文件里也写明了「只准有这一处判定」。
7. **采纳了二轮 review 的 3a/3b 拆分**，并且做成默认关闭的实验开关
   （`LLMQ_OWNER_TIMEOUT_RETRY`，倍率 `LLMQ_OWNER_RETRY_TIMEOUT_MULTIPLIER` 默认 1.5），
   超时预算校准前置。历史数据是「超时后成功的 12 条全部靠换人救活、0 条原地重试成功」，
   这个拆分让风险可控且可回滚。

## 二、建议合入前处理

按「我自己复核过」和「经反方验证」分级。**没标"已核实"的都是未验证线索，不要当结论用。**

评审方式：六路并行只读评审（owner 绑定 / 会话作用域 / WorkAttempt / 日志真实性 / 测试有效性 /
集成风险），共报 40 条；其中 14 条送进「默认它是错的」的反方验证，10 条成立、4 条被驳回。
未经验证的 26 条我另列在第六节，只作线索。

### 2.1 【已核实·最该先修】`llmq work retry` 被 owner 绑定架空了

`main.swift:848`：retry 会清空 `triedPlatforms`（除非 `--same-platform`），
这正是人「明确要求换个平台再试」的表达。但它**不清 `ownerRunnerID`，也不清 `automaticHandoffCount`**。

而派发处 `main.swift:2057`：

```swift
let fallbacks = cand.automaticHandoffCount < 1 ? d.candidates : []
d.candidates = [ownerPick] + fallbacks
```

于是一条**已经用掉那一次自动交接名额**的任务，人工 retry 之后候选里只剩原 owner，
只能反复重跑同一个失败的 Runner，人工换人的意图被静默吞掉，界面上也看不出为什么。

这直接违反设计文档 7.2 表格最后一行：「用户明确要求换人 → 保存进度并交接 → handoff：是」。
建议：`work retry`（不带 `--same-platform` 时）清空 owner 字段，或把这次 retry 标成
「人工授权的交接」，让它绕过自动交接上限。

### 2.2 【已核实】被 kill 的尝试完全不落盘，`Outcome.running` 是死代码

`WorkAttempt.Outcome` 定义了 `.running`，但全仓无人写入：两个写入点
（`main.swift:2258`、`:2441`）都在 `Proc.run` 返回**之后**。
worker 自身被杀（launchd 超时 SIGKILL、崩机、断电）时，那次尝试在账本里完全不存在。

设计 7.2 失败决策表**第一行**就是「worker 重启、进程被系统打断」，
阶段 0 验收写着「一次超时后仍能从 WorkAttempt 看见前后两次尝试」——这条在被 kill 的路径上不成立。

建议：开工前先落一条 `.running`（`attemptID` 已是 UUID，天然可配对），
结束时用同一个 `attemptID` 补终态；孤儿回收时把残留的 `.running` 标成中断。

### 2.3 【已核实】日志措辞仍在说无法证明的话，违反它自己的设计 5.4

`main.swift:2334` 起，在**子进程启动之前**打印：

```swift
case .resume(let id):  print("  接上任务会话 " + id.prefix(8))
case .projectResume:   print("  接上该工作区属于本任务的最近会话")
```

设计 5.4 的正面规定是「已请求恢复会话 `<id>`」，并明令「在没有 CLI 回执或语义验证时，
不打印无法证明的结论」。此刻还不知道 CLI 认不认这个会话——**CLI 随后拒绝会话时，
前后两条日志会自相矛盾**。

整个改造的起点就是这句日志说了 283 次谎（口径见 `context-affinity-review-round2.md`）。
改成「已请求恢复」成本一行。

附带：`.fresh` 分支完全静默，运维分不清三种情况——Runner 本来就不支持会话、
`projectLatest` 的 affinity 校验没过被降级、这条任务第一次跑。5.4 第一条要求的
「Runner 不支持原生会话；沿用工作区和磁盘交接信息」没有实现。

### 2.4 【已核实】`WorkAttempt` 的两个写入点都是 `try?`，账本会无声丢记录

`main.swift:2258` 和 `:2441`。这个账本存在的**全部意义**是「不可覆盖的事实」，
而磁盘满、权限异常、`flock` 失败时记录会静默消失，之后所有基于它的指标
（设计第十一章）都会偏，且没人知道偏了。

这个项目刚因为「磁盘剩 165MB 全线静默烂掉」吃过亏。不要求它中断主流程，
只要求失败时打一句显眼的警告，或记一个失败计数。

（对比：`WorkAttemptStore.append` 的**写入实现本身**比 `TaskStore.append` 更严格，
有完整的部分写循环和 `EINTR` 处理。问题只在调用点把错误吞了。）

### 2.5 【已核实·唯一存活的变异】图内能力泳道的会话隔离没有测试钉住

把 `GraphSession.Context.storageKey` 里的 `|lane:\(capability.rawValue)` 删掉
——同一张图的编码步骤和媒体步骤就会共用一个会话——**14 条测试全绿**。

设计 5.2 明确要求图的作用域含 `capabilityLane`。今天实现是对的，
但这条核心约束没有测试保护，下次重构会静默丢失。

### 2.6 【已核实】把会话接线一行字面回退，测试不会红

`main.swift` 里「用哪套会话作用域」的接线**没有任何测试覆盖**。
把它改回 `GraphSession.mode(repo: task.repo, platform: pick.platform, graphID:)`
——这不是等价改写，是 `git diff` 里那一行改动前的**字面原样**——
全量测试依然全绿，而「按仓库共用会话」这个刚修好的 bug 就回来了。

设计 §10 要求「按仓库共用 session」这个变异必须能让测试变红。现在做不到。

补充（这条我一轮判重了，按反方验证收窄）：`GraphSession.swift` 里遗留的
`mode(repo:platform:graphID:)` / `forget(repo:platform:)` 确实还是 `public`，
但**改造前也是 public，可见性没有回退**，且全仓零调用，生产删除路径已全部改走
`forget(context:)`，新旧 key 命名空间不重叠、条数有界、不参与任何查询。
磁盘上遗留的 `repo:<路径>|platform` 条目无人清理但也产生不出错误结果。
**这属于可选清理（删掉两个死函数 + 启动时剔除非 `v2|` 前缀的旧键），不是缺陷。**
真正要补的是上面那条测试。

### 2.7 【已核实】两个验收点没有对应测试

- **「已开工任务不因额度变化换 owner」**（设计 §10 单测第 7 条）：
  `ContextAffinityTests.swift:175` 看起来在测它，但只放了一个 runner，排序逻辑根本没被执行。
- **阶段 3b 开关「关闭时行为与 3a 完全一致」**：
  `:246` 那条只覆盖了 `shouldRetryOwnerAfterTimeout` 八种组合中的两种，
  而且测的是纯布尔表达式，没有触达真实调用点。

这两条恰恰是这次改造风险最高的地方（3b 要替换一个历史上 12/12 成功的救火路径）。

### 2.8 【撤回】关于「指挥兼任兜底绕过硬闸」——我更正过度了

我一度在口头汇报里说「owner 优先绕过了硬闸」并写进初稿。**这条撤回。**

事实：`Work.swift:526` 明写「**指挥不进候选枚举**」并直接 `continue`，
所以 `Work.swift:663` 那条「高危只有架构师能接 —— 指挥兼任」的兜底，
在**全量 decide 和单 runner 复核下行为完全一致**，owner 复核并没有让它更容易触发。
这条兜底绕过静音/额度/人在用/留白是**改造前就有、且部分是刻意的**行为。

在当前 `roles.json`（只有 claude 是 sensitive，且 claude 是本机指挥）下，
不产生任何行为差异。只有当有人把第二个平台的 `maxRisk` 提到 `sensitive` 时，
才会出现「指挥成为 owner 后恒排第一、人工静音再也释放不掉」的收窄可能——
属于加固建议，不是现网缺陷。

**结论回到原点：owner 优先没有绕过硬闸**（owner 复核走的是
`scheduler.decide(runners: [owner], ...)`，冷却、静音、风险、难度上限全都还在）。

### 2.9 【已核实·我先前判错了】`projectLatest` 的工作区归属只凭「进程起来过」

**先认错**：我口头汇报时说「每条任务用独立 worktree，跨任务污染的路径我没看出来」，
所以把这条降级成「存疑」。**这句话是错的。**

`Work.swift:1820`：

```swift
let key = graphID ?? stableKey(repo: repo, platform: platform)
```

**普通（非图）任务的 worktree 是 `worktrees/<仓库别名>-<平台>`，
同一仓库同一平台的所有普通任务共用这一个目录。** 只有图任务才按 graphID 独立。

实机证据（改造前的历史数据）：两条**互不相关**的普通任务——
`17d7f010`「把 Maw 里的临时调试入口清干净」和 `abc21d46`「给 Maw 补上第一批单元测试」——
都在 `worktrees/maw-qwen` 里以 `qwen -c` 运行，而 `~/.qwen/projects/…worktrees-maw-qwen/chats/`
下**只有一个** 8.8MB 的会话文件 `7b3316d1-…`。它们确实在接对方的对话。

**这次改造把大部分堵住了**：新的 affinity 校验要求
`m[workspaceKey] == 本任务 storageKey`，所以 B 跑过之后 A 再来会降级成 fresh，
不会串味。但残留一个洞：

`main.swift:2420` 只判 `r.exitCode != -1`（即"进程 spawn 成功"）就调用
`GraphSession.markLaunched` 认领该目录的归属——**把"进程起来了"当成了"会话建好了"**。
若这次运行在会话落盘之前就退出，归属标记是假的；该任务下一轮 `-c` 恢复到的，
是这个共用目录里**别人**留下的最近会话。

触发窗口比初报窄（这点反方验证核过）：qwen 在发起模型调用**之前**就把会话落盘，
所以 429 额度耗尽、超时、API 报错这些常见失败**都真的建了会话**，标记是真的、不中招。
真正中招的是"落盘之前就退出"：未登录/凭据刷新失败、`-m` 传了账号不认的模型、
启动期 node/MCP 崩溃。影响面也只限这条任务自己，不会波及第三条任务。

建议：`markLaunched` 只在能证明本次产生了会话时才写（跑前记下 chats 目录最新文件的
名字+mtime，跑完确认出现更新的会话文件），拿不到证据就按设计 5.1
「无法证明时降级 fresh」。注意 `ContextAffinityTests.swift:69` 那条测试现在把
「spawn 即归属」当成期望固定住了，改实现要一并改它。

### 2.10 【已核实】只有 `mutedOn` 被当成人工停用

`main.swift` 的 `releaseIsManual = AgentRoles.isMuted(platform)` 只认静音一种。
而设计 7.3 写的是「`mutedOn`、`canTakeWork == false`、风险上限和复杂度上限的**人工变更**」
整类都算 `manualDisabled`。人工调低风险/难度上限导致的换人，现在会被记成
「自动故障交接」，吃掉任务唯一一次故障兜底名额。

### 2.11 【已核实】图节点继承 lane owner 后，第一次派发就被记成「故障自动交接」

图节点从同泳道继承 owner 之后，若首次派发就换人，`cause` 会被判成 `.automaticFailure`，
把唯一的自动交接名额烧在一个**从未开工**的节点上。与 2.1 叠加，
会让任务过早失去全部兜底。

### 2.12 【已核实】`llmq work attempts <id>` 查不到时谎报「这个任务没有尝试记录」

id 匹配用的是 `hasSuffix`（和邻近的 retry/discard 一致，不是约定问题），
但**匹配不到时打印的是「没有尝试记录」而不是「找不到这个任务」**——
两种情况在人眼里完全不同，一个是"跑过但没记"，一个是"你 id 打错了"。
这个账本刚建起来就是为了让人查真相的，第一层入口不能说岔。

### 2.13 【已核实】普通任务的会话映射只增不减

普通（非图）任务的 session 映射行在任务完成/丢弃时从不清理，
`graph-sessions.json` 会随任务数无限增长。这不影响正确性，
但会让这个文件变成又一个「越用越慢、没人敢清」的东西。

## 三、变异验证明细

在 scratchpad 的仓库副本上做（`--filter ContextAffinityTests`，基线 14 条全绿）：

| # | 把实现改成 | 结果 |
|---|---|---|
| 1 | `automaticHandoffCount < 1` → `< 99` | **红 1 条** ✓ |
| 2 | `shouldRetryOwnerAfterTimeout` 恒 `false` | **红 1 条** ✓ |
| 3 | `assign` 不再累加 `handoffCount` | **红 3 条** ✓ |
| 4 | 人工停用也计入 `automaticHandoffCount` | **红 3 条** ✓ |
| 5 | `storageKey` 的 `task:<taskID>` 换成常量 | **红 2 条** ✓ |
| 6 | `isSessionFailure` 恒 `true` | **红 2 条** ✓ |
| 7 | `storageKey` 去掉 `lane:` | **绿 —— 存活**，见 2.4 |
| 8 | `WorkAttempt.outcome` 的 `decodeIfPresent` 改 `decode` | 绿，但可辩护：`WorkAttempt` 是新文件，没有历史 JSON |
| 9 | `append` 改成空操作 | **测试崩溃退出** ✓（能逮到，但见下） |

变异 9 的附带发现：`testAttemptsPreserveIntermediateTimeout` 直接对读回来的数组下标取值，
账本为空时是 `Fatal error: Index out of range`，**整轮测试进程被中断**，
而不是干净地报一条失败。建议改用 `XCTUnwrap` / 先断言 `count`。

## 四、值得盯住但这轮不必改的

### 4.1 `isSessionFailure` 是「文本当接口」的又一例

`GraphSession.swift:129`：靠 CLI 输出里的英文子串判断会话是否失效
（`session`/`conversation` + `not found`/`no conversation`/`already in use`/`expired`/`invalid session`）。

这是这个项目反复出事的三类形状之一（见 `docs/handover-2026-08-23.md`「踩过就别再踩的形状」第 2 条）：
CLI 换个措辞、或者输出中文，判定就静默失效；反过来误命中则会删掉有效的会话映射。

现在的实现已经做了收敛（先要求出现 `session`/`conversation` 才继续判），比裸匹配安全，
而且有测试覆盖正反例。**这轮不必改**，但建议在文件里写明这是已知的脆弱契约，
并在 `WorkAttempt` 里记录「因文本判定而删除映射」的次数——真出问题时能查得出来。

### 4.2 旧的仓库级会话 API 仍是 `public` 且功能完整

`GraphSession.swift:161` 的 `mode(graphID:platform:)`、`:180` 的 `mode(repo:platform:graphID:)`、
以及 `remember`/`forget`/`legacyKey` 都还在，走的仍是老的 `repo:<路径>|platform` 命名空间。
**生产代码和测试都已经没有任何调用者。**

也就是说：这次修掉的那个 bug（按仓库共用会话），只差一次调用就能回来，
而编译器不会拦。建议删掉，或加 `@available(*, unavailable, message: "...")`，
让它在编译期就回不来。历史映射的清理路径（`forgetGraph` 里对 `workspace|`/`v2|` 前缀的处理）
需要一并确认不会因为删除而漏清。

## 五、我没有验证的部分

- 只跑了 `swift build` 和 `swift test`（897 条），**没有做真机验证**：
  设计第十章「集成与真机测试」列的五项（真实会话复述、构造短超时、构造登录失效、
  跨能力图、手机任务板区分等待与交接）我一项都没跑。
- 阶段 3b 的实验开关只做了静态阅读和变异，**没有实际开启跑过一条任务**。
- `WorkAttemptMetrics` 的聚合口径、ViewFeed/手机端的展示改动，只做了通读。
- `markLaunched` 的残留洞（会话落盘前退出）**没有实机复现**，只做了代码阅读 + 历史数据佐证。
- `isSessionFailure` 的误判概率没有实测。
- 本文引用的「283 次假恢复」「超时 12 条全靠换人救活」等历史数据，
  口径和局限见 `docs/design/context-affinity-review-round2.md`，
  其中「0 条原地重试成功」是现有策略造成的选择效应，不能当作「原地重试无效」的证据。

## 六、口径与方法

- 六路并行只读评审共报 **40 条**，其中 **34 条**送进「默认它是错的」反方验证：
  **26 条成立、8 条被驳回**。本文第二节只收经验证成立、且我自己复核过的。
- 被驳回的 8 条记在这里，避免以后重复提：`.fresh` 分支打印没测试覆盖
  （打印在可执行 target，本包结构使然，非本次引入）、`work-attempts.jsonl` 缺轮转
  （可选增强）、会话失效日志文案自相矛盾（文案打磨）、`WorkAttemptMetrics` 按 platform
  聚合（文档写的就是 platform + 档位，是口径选择）、遗留仓库级 API 是缺陷
  （见 2.6，实为可选清理）、办公室看板 `.handoff` 图标口径（早于本次改造）、
  「指挥兼任兜底被 owner 复核放大」（见 2.8，我自己也判错过一次）、
  `shouldRetryOwnerAfterTimeout` 第三个条件恒真（该条件是防御性写法）。
- **行号会漂**：评审期间 Codex 仍在同一个工作区改 `main.swift`，
  多个验证者都报告行号已偏移。本文尽量给了符号名和代码片段，
  按行号定位不到时请按符号搜。
- 变异验证在 scratchpad 的仓库副本上做，**没有碰作者的工作区**；
  台架自检做过（塞语法错误 → 26 个编译错误），排除假阴性。

