# 实现状态

**这份文件存在的理由**：会话上下文会被压缩，压缩之后只剩一份待办列表 ——
而那份列表把三个已经做完的东西标成「未做」，于是有人（我）照着它去"实现"
一个已经存在的模块，还差点覆盖掉源文件。

**改动代码时顺手更新这里。** 判断依据写在每条后面，别写「大概做完了」。

最后核实：2026-08-11（逐条跑命令 / 查文件确认，不是凭印象）

## 已完成

| 模块 | 文件 | 怎么验证它真的在 |
|---|---|---|
| 采集适配器 | `Adapters.swift`、`OpenCodeAdapter.swift` | `llmq doctor` 列出已验证的采集器 |
| 额度窗口引擎 | `QuotaEngine.swift` | `llmq report` 有「作废预警」段 |
| 多机 iCloud 汇总 | `Store.swift` | `llmq report` 顶部列出两台机器 |
| CLI + 菜单栏 | `Sources/llmq`、`Sources/LLMQuotaBarApp` | `llmq --help` |
| **跨机 mTLS 分发** | `ClusterNet.swift`、`ClusterProtocol.swift` | `llmq cluster ping <节点>` 回「通了…协议 v1」 |
| **上限学习器** | `LimitLearner.swift` | `llmq learn` 输出反解表（官方百分比反解 + 下限估计） |
| **储备任务池** | `ReservePool.swift` | `llmq work reserve` 列出扫到的结构化事实 |
| **评审落地闸门** | `Review.swift` | `llmq work review --auto` 在临时 worktree 里验证合并结果 |
| **高危路径闸** | `Work.swift` `riskyPathsTouched` | 改到 `*.sh`/`Package.swift`/`Tools/**` 不提交、转人工 |
| **高危改动审批** | `Approval.swift` | `llmq work approve <id>`；手机上点按钮走同一函数 |
| **指挥角色** | `AgentRole.dispatcherOn` | `llmq work run` 输出里有「指挥 Claude 本机控制面，不参与竞选」一行 |
| **任务图** | `TaskGraph.swift` | 依赖/就绪/环检测/阻塞传播/产物传递，`llmq work` 里图节点 id 形如 `<图id>s1` |
| **拆解器** | `TaskDecomposer.swift` | `llmq work add` 一个碰 `*.sh` 的任务，会打印「已拆成 N 步」 |
| **按平台留白** | `AgentRole.reserveFraction`、`Work.swift:482` | `llmq runner roles` 的「留白」列；拒绝理由里出现「剩余不足为它预留的 X%」 |
| **手机改留白** | `ConfigIntent.swift` | 往 iCloud `config-intents/` 扔个 json，下一轮 `work loop` 打「配置 xxxx  MiniMax 留白 默认 → 20%」，文件进 `processed/` |
| 飞书通知 | `Work.swift` `Notifier.feishu` | 只做单向通知，审批不走它（要入站回调，和「只开一个端口」冲突） |

## 未完成

- **手机上的留白入口**（2026-08-13）：Mac 侧两头都通了 —— 看板里每个平台带
  `role.reserveFraction`（**生效值**，不是配置里那个「nil 表示继承」的覆盖值）
  加 `reserveIsDefault` 说明这个数是不是默认来的；反向的 `config-intents/`
  也在 `work loop` 里每轮摄入。**缺的是 iOS App 里的界面**（另一个仓库
  `LLMQuotaApp`，另一个人做）。在那之前只能用「文件」App 手写那份 json。
- **意图只有 reserve 一种**：`ConfigIntent.kind` 特意存字符串而不是枚举，
  就是为了让老 Mac 遇到新类型时报「不认识的意图类型」而不是「格式错误」——
  后者是句假话，会把人往错方向带。加新类型只需在 `apply` 里加一个分支。

- **图内并行执行**：DAG 允许多个节点同时就绪，但共用一个 worktree
  的并行写必然打架，所以一次只跑一个（`readyCount` 会把「我知道有 N 个」打出来）。
- **跨机接管一个已存在的节点**：`Elsewhere` 现在能算出「哪台机器上谁接得了」
  并给出可照抄的 `llmq cluster dispatch` 命令，但那是**新建**一个任务，
  不是把这个节点挪过去。挪过去要跨机同步 worktree，还没做。
- **stepIndex 只对新图生效**：改动之前建的节点没有这个字段，
  排序退回按 createdAt —— 而那正是被 ISO8601 抹平的那个。老图显示顺序可能是乱的。

- ~~飞书风险分级异步审批~~ → **改成走 App**（2026-08-12）。
  飞书交互卡片要入站回调地址，和「只允许开一个端口」冲突；
  Ask 通道走 iCloud，零入站端口，App 已经能渲染成按钮。
- **上限学习结果自动写回配置**：`llmq learn --apply` 存在，但当前拟合
  离散度 28.5%（阈值 15%），判为不可信、不会写入。需要更多官方百分比样本。
- **MiniMax 的媒体能力**：`mmx` 能生图/视频/音乐/语音，调度器只把它当分诊器用。

## 各能力的真实成熟度（别看代码写了就当能用）

判据是**真实跑过几次**，不是有没有测试。2026-08-13 实测：

| 能力 | 实测情况 |
|---|---|
| 任务分配 | ✅ 真实跑过几十次。分诊→排除→按额度排→执行→验证→落地全链路验过，高危闸门真拦下过 |
| 跨机派活 | ⚠️ `Elsewhere` 能算出该派给谁并给出命令，但**把已存在的节点挪过去没做** |
| 任务图 | ⚠️ 跑过 2 张。第一张 2 步无依赖、落地 0；第二张 3 步链式，见下 |
| 会话延续 | ⚠️ 语义实测过（两个进程接力回忆出同一个数字），但**真实任务里触发过 0 次** |
| 跨 agent 协作 | ❌ **零验证**。briefing / 共享 worktree / 产物传递都有单测，但没有一次真实的跨平台接力 |

**单测证明不了协作能不能 work** —— 第二个 agent 在别人改过的工作区里干活、
只靠一段文字了解前情，这件事只有真跑才知道。

## 已知问题

- **整套测试偶发失败（约 1/3 概率，1–5 条不等）。** 根因是测试和常驻的
  `com.llmquotabar.worker` 共用真实的 `tasks.jsonl` —— worker 每 5 分钟写一次。
  已经给做真实 worktree 操作的测试类加了 `Paths.appSupportOverride` 隔离
  （它原来直接在真实 Application Support 里建 worktree，和 worker 抢同一个目录），
  但共用任务库这条还没解。
  **三次连续通过不等于稳定**，别把偶发失败当成自己刚改的东西弄坏了。
  彻底的解法是整个测试 bundle 启动时统一重定向 Paths.appSupport。

- **「验证过」不等于「发布过」。** 空窗数据接进 dashboard 那次，
  我拿现场构建的二进制验证了数据是对的，然后转去做别的，
  **漏了 publish** —— 于是手机上「在漏的」那一栏空了好几个小时，
  而 Mac 上算得出 Kimi 连续空 19 个窗口。
  改完 Mac 端的东西，验证之后要么立刻 `llmq release publish`，
  要么在这里记一笔「待发布」。

## 已作废的条目

- **Hermes profile**：那套 kanban 没用（它自带调度器会抢着执行，
  而这里要的是「由额度决定派给谁」），已由自研的 `Work.swift` 取代。
  见 `Work.swift:130`。
- **ModelRouter 改按 base_url 归类**：**做不到**。Claude Code 的会话日志里
  没有任何端点字段（顶层只有 entrypoint/cwd/gitBranch/version，
  message 里只有 model），历史会话根本没记过端点。模型名是唯一的逐条证据。
  见 `Plan.swift` 里那段说明。

## 各家额度上限：能填什么、不能填什么

2026-08 逐个查过官方文档。**结论主要是「哪些填不得」**：

| 平台 | 官方公布 | 能不能填 |
|---|---|---|
| GLM Lite | 5 小时 2,000 积分 / 每周 10,000（[官方](https://docs.bigmodel.cn/cn/coding-plan/overview)） | **不能** —— 单位是积分（按 token 折算 + 工作日 14–18 点 3 倍），和次数/token 口径对不上 |
| Kimi Allegretto | 只说有 5 小时滚动窗口，不给数（[官方](https://www.kimi.com/zh-cn/help/kimi-code/benefits)） | 不能。网上的 300–1200 次/5h 是第三方区间 |
| Claude Max 5x | 不公布 | 不能。曾经的「225」出自已下线的帮助文章，口径是 claude.ai 聊天条数、是下限、且 2026-05 官方翻倍后失效 |
| Codex | 不公布单值，但日志自带 `used_percent` | 不用填 |
| Qwen | 免费 OAuth 层 2026-04-15 关停，走百炼 | 看百炼的周额度 |

**一个来源可靠、口径对不上的数字，比没有数字更危险** —— 它看起来像已经配好了。

<!-- llmq:progress 自动生成，别手改；手写的内容放在这个块外面 -->

## 最近落地（自动记录，别手改）

最后更新：2026-08-13 00:17　共 27 个任务

| 时间 | 干了什么 | 谁干的 | 改动 |
|---|---|---|---|
| 08-12 23:01 | 在本仓库中找到 TaskGraph.swift（在 Sources/ 下，可用 `grep… | Qwen | 1 个文件 |
| 08-11 19:21 | 为 Sources/LLMQuotaCore/Format.swift 里的 Format… | Qwen | 1 个文件 |
| 08-11 19:21 | 在 README.md 的「使用」小节末尾，补一小段说明 llmq work loop 这… | Claude | 1 个文件 |
| 08-11 19:21 | 在 SECURITY.md 末尾加一节「日常自查清单」，用无序列表列出 4 条：跑 llm… | Claude | 1 个文件 |
| 08-11 19:21 | 在 README.md 里加一小节「从手机派任务」，说明把一个纯文本文件放进 iCloud… | Claude | 1 个文件 |
| 08-11 19:21 | 在 Sources/LLMQuotaCore/Format.swift 的 Format.… | Claude | 1 个文件 |
| 08-11 19:21 | Add a short note near the top of README.md sa… | Claude | 1 个文件 |
| 08-11 19:21 | 在 SECURITY.md 里把跨机那节的示例命令更新一下 | Claude | 1 个文件 |
| 08-11 09:57 | 在 Format.swift 顶部加一句文件说明注释 | Claude | 0 个文件 |
| 08-10 21:30 | 在 README.md 顶部的项目简介下面加一行，写明本项目零第三方依赖、只用 Swift… | Claude | 1 个文件 |
| 08-10 21:29 | 把上次那个问题修一下 | Claude | 0 个文件 |

**卡着的**：

- `42266d0f` 在跑 — 在 LLMQuotaCore 仓库里为已有的 WasteMeter 增加命令行入口 llm…
- `70b06e19` 等人工确认 — ⚠️ 本步骤修改仓库根目录的 `build-app.sh`。按 SECURITY.md 第三…：没有平台能接：Qwen（任务风险是高危，而开发最多只接常规的活）；Kimi（任务风险是高危，而主力最多只接常规的活）；火山方舟（任务风险是…
- `71e37b07` 失败 — 把 Package.swift 里的 swift-tools-version 升一档，并确…：（测试风险闸门用的，已作废）
- `83d68ae6` 失败 — 为 Sources/LLMQuotaCore/Cooldown.swift 里的每一个 p…：Claude：超时被终止 / Qwen：超时被终止 / Kimi：. Your quota will be refreshed in th…
- `2d301be3` 失败 — 把 Sources/LLMQuotaCore/Format.swift 里 Format.…：分类器验证用例，手动取消
- `d2c5db6d` 失败 — 修改 build-app.sh，让它在编译前先跑一次 swift test，测试不过就中止…：分类器验证用例，手动取消
- `f70ac3f4` 失败 — 占位任务，只为看调度决策：占位任务，手动取消
- `e97fae4c` 失败 — 为 Sources/LLMQuotaCore/Format.swift 里的 Format…：Claude：Failed to authenticate: OAuth session expired and could not be…

<!-- /llmq:progress -->
