# M2 画面捕获服务退出调查（2026-09-07）

实际读取 M2 `192.168.31.78` 的系统诊断报告、Kimi 原会话 agent-23 工具调用、进程及工作目录。未重启/擦除模拟器，未停止实际模型执行器，没有修改游戏或配额程序业务代码。

## 确认事实

- 今日 20:55:16.0218 与 21:02:21.3584 两份 `.ips` 均为苹果 `SimRenderServer`，异常 `EXC_BREAKPOINT / SIGTRAP`，故障队列 `com.apple.display.captureservice`，前三个模块偏移完全相同。
- Kimi agent-23 分别在 20:55:15.406 与 21:02:20.779 执行该模拟器的 shutdown/boot，距异常分别 0.616 与 0.579 秒。当时正反复尝试底层录屏，记录显示停止操作给过包裹 shell 的 PID。
- 检查时实际录屏 PID25644 已遗留约35分钟，父shell为25641，命令和cwd均指向已结束的 level-camera-check 子任务。实际调用 `kill -INT 25641` 不能作为其子录屏已结束的证明。
- 另一份 axe `.diag` 为约89分钟累计8.59GB写盘的资源诊断，`Action taken: none`，并非崩溃报告。
- 今日09:12 Jetsam报告中被标记 `per-process-limit` 的是 knowledgeconstructiond，LLMQuotaBar/llmq仅列为活跃进程，没有被杀原因。M2内存32GB，不能由这份报告断言配额程序内存崩溃。
- 截至21:39，LLMQuotaBar自19:32发布启动后持续运行，cluster/worker/projector亦在运行，未发现今日LLMQuotaBar/llmq本体崩溃报告。

## 判断与处置

两次可确认的触发点是录屏未收尾时关闭模拟器，捕获服务随后断言退出；报告未给出苹果内部具体断言文本，不声称修复其内部实现。没有为复現故意再次制造崩溃。

按实际完整命令、PID与工作目录重新核对后，只向遗留simctl录屏PID25644发送SIGINT；确认退出，随后查无simctl/axe录像进程残留。未删除录像、源码或已有证据。

已发布持久协作裁决 `m2-capture-lifecycle-20260907`：同设备单一录屏Owner；配对使用既有XcodeBuildMCP start/stop；确认进程退出与视频可读之后才关机/重启；禁止同时混用多套录屏、删除仍在录制的文件或把后台shell PID当录像PID。该流程避免本次已观察到的触发条件，未宣称长期稳定性验证或苹果缺陷已根治。

## 游戏方向

用户最新要求“停止美术整改，优先完整可玩”已通过正式协作事件 `flint-playability-user-decision-20260907` 及TaskStore原子转换写进原任务提示词首部和handoff说明。保留Kimi Owner、分支、会话与已完成的2ea3ba9等四个提交，不篡改进度或把queued写成running。要求普通入口的胜利、失败、重开闭环及真实连续证据，取消旧美术待裁决要求。原任务阶段完成后存在最多5分钟的派发暂缓；这是排队逻辑，不是程序崩溃。

21:42 原会话实际收到新提示：布尔核验“停止美术整改”“普通玩家实际入口”和录屏裁决事件ID均存在。新执行 `3db8baa1-8ae6-4541-a342-a4d8a8b06d09` 为running/projectResume，基线为最新`2ea3ba97c938924c1bdd4d2affd8062b1b3a7998`；未回退已提交成果。这是新目标到达与执行开始的证据，不代表游戏闭环已验收通过。
