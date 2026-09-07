# Flint 原任务被同提交别名分支阻塞

2026-09-07 在原执行机器核对：Kimi 任务 i31c8eb29e2a173f 最后有效提交为 afb4ae1（2026-09-06 21:21），之后执行器反复启动但未调用模型。基线闸等待 agent/minimax/ie95050092681008 的 409 个文件；该分支与 Kimi 分支实际上都是 afb4ae17ade90f03b2e45b80a90cea321a9e6818。

根因：BaselineFreshness.blocks 只剔除分支名相同的项，跨平台接力和评审分支同提交或祖先提交仍被视为缺失基线。任务本身已拥有成果，却被要求等成果合入才能继续。

修复：调度入口传入候选仓库；使用本地分支完整提交 ID 比较，相同或阻塞分支已包含在候选历史中时放行。新提交、分叉、引用缺失及 Git 读取失败继续阻塞。未关闭基线保护，未改 Owner、额度预留、数据协议、工作目录或会话选择。

真实 Git 回归在旧行为下 9 项测试出现 3 条失败断言；修复后基线、任务类型和暂停相关 28 项全部通过。日志位于 qa-reports/2026-09-07-baseline-continuation/。完整 Core、移动端独立验收、发布及原任务实际恢复结果在同目录收尾记录中分别报告，不以源码修复代替生产恢复。

## 服务端回归结果

全套发现 1553 项：1551 通过、0 失败、0 丢失，2 项登录钥匙串测试因默认交互门禁跳过（ClusterNetTests/testPassphraseSurvivesRelaxedAccess、testScratchKeychainCreatesAndCleansUp），不能计为通过。它们涉及登录钥匙串，与本批 Git 基线判定无改动关联。arm64/x86_64 通用 Release 编译成功。被测源文件 SHA-256 记录于 source-fingerprint.json；完整测试汇总见 core-full-summary.json。

## 独立验收

非实现者 independent_model_acceptance 已逐行审查本批实现、实跑 iPhone 完整回归（135 项中 133 通过，2 项 iPad 专属在 iPad 补齐）、iPad 相关 5/5 通过，当前 Core 生成的隔离任务板实际显示和真实动作回执回读 1/1 通过。实现者亦打开检查最终 iPhone/iPad 截图。完整 iPad 回归、物理手机、真实 APNs/iCloud 传播未验证；App 源码未变，本批不发布新手机二进制。归档报告见独立验收记录；生产恢复另行核验。

## 发布与实际恢复

修复提交 `ede6c59` 已推送；签名发布 `a24601a0bae4` 已由 Mac mini、Apple Silicon MacBook Pro、Intel MacBook Pro 三台在线机器确认。执行机器与发布机的实际 CLI/App SHA-256 一致，执行机器后台已切换新版本。

原任务在 2026-09-07 10:09（北京时间）解除暂停，10:10:43 进入新执行轮次，仍为 `kimi.code`、原分支和原工作区，`sessionAction=projectResume`。Kimi 会话 ID 与前一轮相同，续接第 31 轮；10:12:06 收到新模型响应，并成功读取已认可的角色交付标准，另调用项目协作上下文工具。这里的“恢复”指实际模型和工具恢复执行，不代表整个 Flint 游戏已完成或未来不会遇到其他阻塞。详细生产快照、发布日志及工具事件保存在本机本批 QA 目录。
