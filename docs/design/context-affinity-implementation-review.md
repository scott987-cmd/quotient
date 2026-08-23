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

**这批改造质量高，方向正确，可以合入**，但下面第二节的 8 条建议先处理 ——
其中 2.1（人工 retry 被架空）是操作面的实际回归，2.2 / 2.3 / 2.4 是它自己的设计文档
明确要求、实现没做到的，2.5 / 2.7 是核心验收点缺测试——其中两条是它自己的设计文档
明确要求、实现没做到的（措辞、泳道隔离的测试），另两条会让新加的账本在真出事时丢数据。

硬事实：

- **全量 897 条测试 0 失败**（改造前 886 条，新增 11 条）。
- **变异验证：9 个变异，7 个被测试逮到，1 个可辩护，1 个真存活。** 明细见第三节。
- 六路并行只读评审共报 40 条，14 条经反方验证，**10 条成立、4 条被驳回**；未验证的 26 条只作线索。
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

### 2.6 【已核实】旧的仓库级会话 API 仍是 `public` 且功能完整

`GraphSession.swift:161` `mode(graphID:platform:)`、`:180` `mode(repo:platform:graphID:)`、
以及 `remember`/`forget`/`legacyKey`，走的仍是老的 `repo:<路径>|platform` 命名空间。
**生产代码和测试都已无调用者。**

也就是说，这次修掉的 bug（按仓库共用会话）只差一次调用就能回来，编译器不拦。
设计 §10 要求「按仓库共用 session」这个变异必须能让测试变红——现在做这个变异一行就够，
而且不会红。建议删掉，或加 `@available(*, unavailable, message: "...")`。
删除时需一并确认 `forgetGraph` 里对 `workspace|` / `v2|` 前缀的清理路径不受影响。

### 2.7 【已核实】两个验收点没有对应测试

- **「已开工任务不因额度变化换 owner」**（设计 §10 单测第 7 条）：
  `ContextAffinityTests.swift:175` 看起来在测它，但只放了一个 runner，排序逻辑根本没被执行。
- **阶段 3b 开关「关闭时行为与 3a 完全一致」**：
  `:246` 那条只覆盖了 `shouldRetryOwnerAfterTimeout` 八种组合中的两种，
  而且测的是纯布尔表达式，没有触达真实调用点。

这两条恰恰是这次改造风险最高的地方（3b 要替换一个历史上 12/12 成功的救火路径）。

### 2.8 【已核实·我要更正自己一句话】高危任务的「指挥兼任」兜底能绕过硬闸

我在口头汇报里说过「owner 优先没绕过任何硬闸」，**这句话要收窄**。

一般路径确实没绕：owner 复核走的是 `scheduler.decide(runners: [owner], ...)`，
冷却、静音、风险、难度上限全都还在。

但 `Work.swift:651` 有一条既有兜底：`ordered.isEmpty` 且任务是 `.sensitive` 时，
「高危只有架构师能接 —— 指挥兼任」会把 dispatcher 平台直接塞进候选。
owner 复核用**单 runner**调用 `decide`，`ordered.isEmpty` 变得非常容易成立
（只提供了一个 runner，它被闸掉就空了），于是刚被静音/额度/留白闸掉的 owner
可能被这条兜底重新捞回来。

这条兜底是**改造前就有的**，不是这次引入的；但 owner 复核让它更容易触发。
建议：owner 复核调用 `decide` 时显式关闭 dispatcher 兜底，或在兜底里要求
`runners.count > 1`（即「确实全场没人能接」而不是「只问了一个人」）。

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
- 六路评审报的 40 条里，只有 14 条经过了反方验证；未验证的 26 条见第六节，只作线索。
- `markLaunched` / `isSessionFailure` 的实际触发概率没有实测，只做了代码阅读。
- 本文引用的「283 次假恢复」「超时 12 条全靠换人救活」等历史数据，
  口径和局限见 `docs/design/context-affinity-review-round2.md`，
  其中「0 条原地重试成功」是现有策略造成的选择效应，不能当作「原地重试无效」的证据。

## 六、报了但**没经过验证**的线索（不要当结论）

六路评审共报 40 条，其中 14 条送了反方验证。下面这些**没有验证过**，
我只做了粗读，列在这里供作者自行判断。按我粗读后的可信度排序：

**看起来值得查的**

1. `GraphSession.swift:131` `isSessionFailure` 在**整份 stdout + stderr** 上做子串匹配。
   agent 自己讨论 session、或输出里带 "invalid session" 字样的文件内容，就会被判成会话坏掉：
   删掉仍然有效的映射，并把这一轮算成会话故障。**这是「文本当接口」的又一例**
   （见 `docs/handover-2026-08-23.md` 三类复发形状第 2 条）。
   现有实现已做收敛（先要求出现 `session`/`conversation`），也有正反例测试，
   但匹配范围是整段输出这一点没变。建议至少把匹配范围收到 stderr 末尾若干行。
2. `main.swift:2266` / `:2380`：工作区创建失败、以及图节点第一次继承 lane owner，
   都可能被记成「自动故障交接」，把唯一一次自动交接名额烧在**从未开工**的节点上。
   若属实，会和 2.1 叠加成「任务提前失去所有兜底」。
3. `main.swift:2062`：只有 `mutedOn` 被当作人工停用；风险上限 / 难度上限的人工调整
   仍记成故障自动交接。设计 7.3 写的是「人工变更」整类，不只静音。
4. `main.swift:2576`：CLI 明确拒绝会话这件事在 `:2547` 算出来、`:2549` 用掉，
   却没有任何字段落盘，设计第十一章的「按 Runner 分开的明确拒绝次数」因此算不出来。
5. `WorkAttempt.swift:182` / `:161`：工作区创建失败的记录混进尝试总数和恢复率
   （`workspacePrepared` 字段写了但全仓没有读者）；聚合键用 `platform` 会把
   `minimax.media` 和 `minimax.review` 并成一行。
   （聚合键这条在反方验证里**被驳回**：文档写的就是 platform + 档位，属于口径选择而非缺陷。）

**我粗读后存疑的**

6. `main.swift:2390` `markLaunched` 把「进程起来了」当成「会话已创建」
   （只要 `exitCode != -1` 就认领工作区的 `projectLatest` 归属）。
   报告说一次秒退就能抢走归属、导致下一轮恢复到别的任务的会话。
   **但每条任务用独立 worktree**，跨任务污染的路径我没看出来；
   同一任务重试时的行为值得确认，但风险应该没有报告说的那么大。

**反方验证已驳回的（记在这里避免以后重复提）**

- 「`.fresh` 分支的打印没有测试覆盖」——打印在可执行 target 里，本来就没有单测目标，
  是这个包的结构事实，不是本次引入的缺陷。
- 「`work-attempts.jsonl` 没有轮转」——属可选增强，没有错误输出、没有误导自动决策，
  设计也没要求。
- 「会话失效日志里『下次从零读一遍仓库』与紧接着的 fresh 重试自相矛盾」——文案打磨，
  不是正确性问题。
