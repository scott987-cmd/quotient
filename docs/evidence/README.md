# 证据：储备池 todoNote 不再误报自身分节注释

分支：`agent/kimi/707405e5`（commit `b76a754`）
改动：`Sources/LLMQuotaCore/ReservePool.swift:178` 的分节注释
`// TODO / FIXME：…` 改写为 `// 待办标记：…`，让扫描器不再把自己的注释当欠账。

## 怎么看

两个文件是同一条命令在改动前后各跑一次的真实输出：

    llmq work reserve --repo /tmp/llmq-repo-copy --limit 20

（`/tmp/llmq-repo-copy` 是本仓库 `Sources/` + `reviews/` 的拷贝；直接扫仓库本体
会被 `isGenerated` 的 `worktrees` 路径排除规则整体跳过，扫不出任何东西 ——
本工作区就在 `worktrees/` 下。`LLMQ_HOME` 指向空目录，让任务队列为空，
否则输出会在列出事实之前就因「队列里还有活」提前返回。）

- `reserve-before.txt` —— main（`3bea34c`）构建的二进制 + 旧注释：
  扫出 1 条事实，正是误报本身：
  `ReservePool.swift:178 「/ FIXME：写代码的人当场留下的欠账」`。
- `reserve-after.txt` —— 本分支构建的二进制 + 新注释：
  同样的 1 条变成了**阳性对照**（临时放进去的真 TODO 文件
  `PositiveControl.swift`），ReservePool.swift 不再出现。
  这同时证明扫描规则没有被改坏：真 TODO 照样抓得到。
