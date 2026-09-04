# 移动端通知详情丢失修正

日期：2026-09-03。状态：代码修正，尚未发布；不能称用户手机已修复。

## 现场证据

- 03:58:33 UTC M2 的 `progress-stalled-i31c8eb29e2a173f` 提醒报告停滞 121 分钟。
  旧 `Nudge.targetPage` 不识别 progress/question，旧 iOS 解析器只接受三个页面，
  因而这类横幅只能打开 App，没有对应详情。
- 04:05:25 UTC，M2 自己的 review 页有 8 张成果卡；04:05:26 UTC，云端和 Mac mini
  的同名 `views/review.json` 只有 Mac mini 的 2 张卡。三台机器向同一文件写局部页面，
  即使发送瞬间内容就绪，之后也会被覆盖。只加推送前“页面存在”检查不能解决。
- 旧 payload 不携带独立事件 ID 或来源机器；详情退场、同步延迟或同名页面被覆盖后，
  手机无法还原发送时的内容，也不保留 APNs 正文作为兜底。

## 实现与边界

1. 每个通知生成 `notification-details/<SHA256>.json`，身份包含机器、事件 key、正文、
   内容；同一内容重试保留最初时间。写本地与 iCloud、读回核对后才发送横幅。
2. 快照只保存供查阅的投影，不新增任务账本。移除所有卡片/区块动作，保留全文和证据引用；
   用户到“当前事项”才可操作。历史媒体仍可能被既有清理规则清理，不承诺永久视频存档。
3. 本次 milestone 必须有对应 SHA 卡片且本次证据就绪；不让无关旧卡片的已清理媒体
   阻断新提醒。其他通知仍检查其快照引用的媒体。旧卡片文字保留。
4. progress 从精确 taskID 的任务读取内容，question 从仍关联 blocked 任务的已发布问题读取；
   没有对应记录则不伪造详情。额度等纯文本提醒保留正文。
5. `review/blocked/playbook` 加发机器独占 `page-<SHA256(machineID)>`，保留旧文件兼容旧 App。
   新 App 汇总分机页并对卡片 ID 增加来源命名空间；过期来源只读。数量与页面共用汇总。
6. payload 同时携带旧 page、新 notificationID 和 sourcePage。iOS 严格校验路径，点开只读
   一个通知文件，不将历史详情加入全局 15 秒扫描；重叠读被抑制，目录切换丢弃旧读结果。
7. 旧通知没有独立快照，不能追溯恢复已丢失的全文，但会显示收到的正文和当前事项入口。
   新快照未下载时显示明确说明、手动重试与低频自动重试，正文立即可读。
8. 通知 delegate 在 AppDelegate 启动完成前绑定，不等 SwiftUI `.task`；通知直接打开的
   来源页与汇总页使用相同的过期只读保护。

部署需同时升级三台 Mac 与 iOS；只刷新旧版客户端不会获得新点击逻辑。
混合版本期间，只发旧版通用页面的机器可能在新客户端分机汇总里缺席，所以要配套升级。
Flint 未被创建新任务、重试、重启、改派或改分支。

## 可复现验证

代码仓库：`/Users/dushibing/dev/LLMQuotaBar`、`/Users/dushibing/dev/LLMQuotaApp`。

- `swift test --filter NotificationDetailTests`：新增 8 项通过，日志
  `/tmp/llmq-notification-core-final-focused.log`。
- 第一轮服务端全量 `swift test --parallel`：1395 项通过；新增精确捕获及旧媒体回归后，
  最终 1397 项通过、退出 0，日志 `/tmp/llmq-notification-core-full-final.log`。
- 手机 `xcodebuild test -project LLMQuotaApp.xcodeproj -scheme LLMQuotaApp
  -destination 'platform=iOS Simulator,id=B21093BB-36F9-4E3B-8DBD-2B8BF8051AAB'
  -parallel-testing-enabled NO`：56 项单元/契约通过；12 项 UI 中 10 项通过、
  2 项因 iPad 宽度条件跳过。日志 `/tmp/llmq-notification-app-full.log`。
- 更多页数量改用相同汇总后的单元/通知 UI 回归：56 项单元及 2 项 UI 通过，
  `/tmp/llmq-notification-app-final.log`。
- `xcodebuild ... -configuration Release -destination 'generic/platform=iOS'
  CODE_SIGNING_ALLOWED=NO build` 通过，最终日志 `/tmp/llmq-notification-app-release-final.log`；
  这是无签名构建，不是上传或真机安装。
- 变异 1：把分机页退回通用页、保留历史动作、绕过媒体检查、删掉 progress 路由，
  6 项测试出现 5 个失败断言，日志 `/tmp/llmq-notification-core-mutation.log`。
- 变异 2：把手机退回最后写入单页、丢正文、不展开全文，2 个契约及 2 个 UI 测试
  出现 7 个失败断言，日志 `/tmp/llmq-notification-app-mutation.log`。
- 变异 3：错 taskID、丢提问正文、让无关旧媒体阻塞，8 项测试出现 4 个失败断言，
  日志 `/tmp/llmq-notification-core-mutation-v2.log`。所有变异源码已恢复。
- 新增过期来源直接深链测试先在缺保护实现上出现 2 个失败断言
  (`/tmp/llmq-notification-app-stale-red.log`)；冷启动 delegate 测试在原启动时序上出现
  1 个失败断言 (`/tmp/llmq-notification-app-delegate-red.log`)，随后补齐对应实现。
- 最终手机全量曾因两个构建共享 `build.db` 而未启动，记录为环境/编排失败，不算通过：
  `/tmp/llmq-notification-app-full-final.log`。Release 构建完成后串行重跑，日志
  `/tmp/llmq-notification-app-full-verified.log`：最终 57 项单元/契约通过，12 项 UI 中
  10 项通过、2 项因 iPad 宽度条件跳过，退出 0。

UI 测试使用明确的 fixture 和 DEBUG 通知注入，覆盖同一解析及呈现入口；没有伪装真实 APNs。
待发布、配套更新后验证系统横幅及用户物理手机。旧 TestFlight build 202609030202 不含本次修改。
