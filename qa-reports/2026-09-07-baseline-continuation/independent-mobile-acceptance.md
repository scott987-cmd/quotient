# Flint 续作基线修复独立验收

日期：2026-09-07。验收者：/root/independent_model_acceptance，非实现者。实现者为 /root。验收者未修改业务、测试断言或美术资源，未操作生产任务、Owner、Agent、iCloud 或服务。

结论：本批代码审查和移动端独立验收通过，可以交给实现者按既有流程发布并验证真实任务恢复。此结论不表示生产任务已恢复，也不替代发布后实际模型进程及新输出的证据。

## 版本

Core 基础 HEAD 9f123c3e86ffac313a8d198b606fd498e9bbaa9e，加本批冻结的 BaselineFreshness.swift、Sources/llmq/main.swift、BaselineFreshnessTests.swift；完整 reviewed-core.diff 留存。App HEAD 0e7eccd1ad6e0d3ca3977897585c4c3f335cfacd，无业务改动。app-fingerprint.json / core-fingerprint.json 记录逐文件内容 SHA256；source-aggregate-hashes.json 记录有序文件列表摘要；final-fingerprint-check.json 证明验收结束时两端内容均未变化。后续仅提交这些相同内容时可以绑定新提交，不得给不同源码套用本报告。

## 代码审查

已逐行审查函数、真实调度调用和新增 Git 测试，详见 code-review.md。相同提交/已包含的祖先允许原候选续作；更新或分叉提交仍阻塞；缺引用、错误仓库及 Git 错误保守。没有反向祖先豁免或漏接实际调用。没有改变 Owner、原会话、平台预留或成果质量门。未发现本批应修复的阻断性问题。

已读取实现者旧行为红测日志：新增真实 Git 回归导致失败，归档 implementer-baseline-red.log。验收者没有删测试、弱化断言或制造跳过换取绿色。

## 模拟器测试

iPhone 15 Pro Max / iOS 26.5，B21093BB-36F9-4E3B-8DBD-2B8BF8051AAB：现有完整单元/UI 135 项，133 通过、0 失败、2 条件跳过，543.479 秒。两跳过仅为 iPad 专属横屏团队与协作，已在下面 iPad 真正执行通过。完整日志 iphone-full.log，结果 iphone-full.xcresult。

iPad Air 13 M4 / iPadOS 26.5，866C752A-8D86-4A98-9CAC-EC1E0B02FB9A：按本批只有服务端分支判断、无手机协议或布局变更的风险范围，运行相关 5 项，5 通过、0 失败、0 跳过，65.236 秒：横屏团队控制台、横屏协作入口、同分支不同来源机器独立处理、无额度快照仍读任务/问题、旧 schema 显示质量原因。不是完整 iPad 回归。日志 ipad-risk.log，结果 ipad-risk.xcresult。

全部使用本轮独立 /tmp/llmq-baseline-independent-mobile-build，双设备串行运行。编译与测试由 XcodeBuildMCP 执行。

## 当前 Core 到手机闭环

用当前已编译的 Core 模块/对象重新编译隔离生产者，不用历史 JSON 冒充当前输出。生产者源、二进制哈希、模块哈希、编译运行日志均在本目录。Paths.appSupportOverride 与 machineIDOverride 显式指向 /tmp 隔离目录。

1. 实际 ViewFeed.publish + MirrorService.sync 产生方案和路由动作。
2. 完整 iPhone 测试中的真实 Store 写入隔离动作。
3. 当前 Core 消费者验证错误机器不能消费；目标机器实际处理并改变隔离 Playbook，然后发布成功回执。
4. 同一 iPhone 定向回读 1/1 通过，0 跳过；iphone-real-receipt.log / .xcresult 留存，完整 JSON 归档 iphone-real-chain-after-consumer/。
5. 实际 TaskBoard.build → TaskBoardStore.publish → MirrorService.sync 生成当前 Kimi 任务板，完整 iPhone 对真实输出的任务 ID、平台、running、进度阶段/摘要/证据计数断言通过。原始生产输出归档 actual-taskboard-output/。

人工实跑手机使用唯一干净 /tmp 夹具目录，只复制上述当前 Core 原字节输出；目录路径在 actual-ui-root.txt，启动 env 在 iphone-current-isolated-launch.json。屏幕实际显示 Kimi running、来源 MacBook Pro · QACO、当前结构化进度、运行计数 1；额度未同步明示，不把缺额度当无任务。此前复用历史夹具时截到旧额度快照，保留 iphone-current-core-taskboard.jpg 作为诊断，不用它代表干净生产者画面。

## 已独立打开检查的截图

- iphone-current-core-isolated.jpg：当前真实 Core 输出在手机显示，唯一干净隔离目录。
- iphone-source-attachments/4D346758-A4C0-459D-AC36-0E3253BE27D7.png：同分支 A 已提交等待目标 Mac，B 仍独立待确认，机器来源与状态没有串线。
- ipad-team-attachments/B55E3250-D560-494C-A2B4-52732D923C95.png：横屏两机器工位、任务控制台及进度可见，关键文字无裁切。

## 未覆盖

没有验证真实生产任务调度、Kimi 原会话恢复或模型新输出；由实现者部署后验证。没有测试物理手机安装、真实 APNs、真实 iCloud 跨机传播或故障恢复。本批 App 源码未变，未发布 TestFlight。测试通过不证明所有未来停工原因都不会发生。
