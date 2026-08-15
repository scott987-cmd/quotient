# 调度会话章程

两个会话分工干活，**互不干扰、共享全部事实**。这份文件是调度会话的开工说明。

## 为什么这样分

一个会话既派活又改代码时，两件事互相打断：改到一半去看任务、盯任务时又想动手改。
更糟的是 `llmq release publish` 会重启 worker、杀掉正在跑的 agent —— 改代码的人
随手一发布，派活的人的产出就没了。分开之后这条冲突从「靠记性」变成「靠边界」。

## 事实怎么共享（关键设计）

**不同步对话，共享状态存储。** `tasks.jsonl`、冷却台账、待审分支、办公室事件流
本来就是唯一事实源，两个会话读的是同一份数据，不存在「谁的信息更新」这种问题。

开工第一件事、以及每隔一段时间：

```bash
llmq brief --since 2
```

一页看完：这两小时内完成/失败/卡住/落地/丢弃了什么，此刻在跑几个、堵着几个、
待审多少、谁在冷却、有几个问题在等人回话。**不维护已读游标**（那东西会漂移），
时间窗由你给。

## 调度会话管什么（你）

- **派活**：`llmq work add "..." --repo <别名> [--platform <点名>]`
- **盯进度**：`llmq brief`、`llmq work list`
- **解卡**：回答 agent 的提问、`llmq work retry <id>`、`llmq work discard <id>`
- **产能调度**：看 `llmq report` 的作废预警，哪个平台的额度快清零了就派活给它
- **资产包产线**：见 `~/dev/AssetPacks/PIPELINE.md`，生成→终审→打包→上架
- **游戏终审**：Maw / Greed 的产出**必须模拟器实跑截图**才算验收
  （两个仓库已标 `manualReview`，不走自动落地）

## 程序优化会话管什么（另一个）

- 改 `~/dev/LLMQuotaBar` 的代码、修调度器的 bug、加能力
- 改游戏代码本身（Maw / Greed 的手感、画面、架构）
- **发布 CLI**（`llmq release publish`）

## 唯一需要协调的一件事

**发布会打断在跑的任务。** 程序优化会话发布前必须确认 `llmq work list | grep running`
为空；调度会话如果正好要派长任务，发布就得等。真踩过四次，一次差点毁掉 26 分钟的产出。

其余互不干涉：调度会话不改 llmq 的代码，程序会话不派活（自己测试用的除外）。

## 常用命令速查

```bash
llmq brief --since 4          # 四小时内发生了什么 + 此刻全景
llmq work list                # 全部任务
llmq work review --repo maw   # 某仓库的待审产出
llmq report                   # 额度与作废预警
llmq work retry <id>          # 重排
llmq work discard <id>        # 丢弃
llmq cluster diagnose <节点>  # 另一台机器的健康检查
```

## 当前在跑的三条线（2026-08-15 09:15 交接快照）

1. **Greed 黑屏修复**（图 e12dc54c，6 步）：s1 卡住在等人回答一个问题 ← **要先处理这个**
   - 背景：Greed 构建通过但画面全黑，13 张美术一张没显示；根因是代码用
     `Image("card-back")` 按 Asset Catalog 名字加载，而资产是散装 PNG
2. **Maw 视觉升级**（图 a90f8b8c，6/8）：s5「PlayerNode 动感」失败，s8 被冻住等上游
3. **资产包 pack-03-forest**（幽林精灵，17 项）：已生成并落地，等终审
   （裁签名 → 抽验底边 → 打包 → 上架，流程见 AssetPacks/PIPELINE.md）

## NAS 归档（2026-08-15 接入）

- 挂载点：`/Volumes/scott_存储空间4/数字员工档案`（UGREEN-4117，SMB）
- 目录：`logs/`（agent 执行日志，按时间戳分批）、`tasks/`（轮转出来的老任务记录）、
  `发布归档/`、`资产原件/`
- 命令：`llmq archive`（目标已记住，直接跑）
- 分工：**日志和老任务记录归档到 NAS，worktree 直接删不备份**
  （97% 是 .build 编译产物，源码在 git 分支里）

**两条不能忘的**：

1. **别把 git 仓库放 NAS 上**。macOS 26 对网络卷有独立 TCC 门，launchd 起的
   worker 没授权访问会**永久挂起**（不是报错，是挂住）—— 和今早 iCloud
   那次一模一样的失败模式。git 在 SMB 上的文件锁也不可靠，而我们重度依赖 worktree。
2. **别把 archive 挂进 worker 循环**。同上：worker 是 launchd 起的，
   碰网络卷有挂死风险。archive 只在人手动跑（或前台会话里跑）。
