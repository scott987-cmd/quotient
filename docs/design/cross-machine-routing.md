# 设计：把活派给「装了那个 CLI 的那台机器」

> **状态：搁置(老板 2026-08-23 拍板「先不做跨机调度」)。**
> 不要按这份文档动手。它还缺一块关键设计:**产物怎么回来** ——
> 转交出去的活会在对端跑出一个发起方永远合不了的分支(两台机器是各自独立的克隆,
> 代码不跨机),下游的审核/落地/验收全接不上,等于制造新的黑洞。
> 哪天要做,先补「产物回传」(倾向:两台互加 remote,执行完由执行方 git push 回发起方),
> 再谈调度转交。
>
> 现状不变:**GLM/ZCode 只在 MacBook 上派得动,在 mini 上派 GLM 的活会照旧被跳过。**

架构决定，2026-08-23。老板：「MacBook 的 ZCode 还是没有在移动端展示」
「我将来会主要用 ZCode 使用 GLM」。

## 问题

`Work.swift:492`：本机没装的执行器 → `Rejection(.permanent)`。
调度只看**本机**装了什么。而两台机器装的东西不一样（真实数据 2026-08-23）：

| 机器 | 装了 |
|---|---|
| Mac mini（派活的那台） | claude, codex, qwen, kimi, minimax, volcark |
| MacBook Pro | claude, codex, qwen, kimi, **glm(ZCode)**, volcark |

后果：**GLM 只在 MacBook 上有，而派活的是 mini → GLM 永远接不到活。**
worker.log 实锤：「空窗填活 GLM 5 小时窗口一轮都没开，已经闲了 10 小时 45 分」，
每轮都在喊，一轮都填不进去。老板的 GLM 订阅在空烧。MiniMax 反过来只在 mini 上有，
同样的坑对 MacBook 派的活也成立。

## 不做什么

- **不做任务库同步。** `tasks.jsonl` 是机器本地的，两台机器合写同一份队列
  会把 RepoLease、孤儿回收、限流这些全部拉进跨机竞态，得不偿失。
- **不做「谁都能跑」的抽象。** 执行器就是本机的进程，跨机跑不了。

## 做什么

派活时多一步：**本机跑不了、但对端能跑 → 通过集群把这条任务提交给对端**，
本机把它标成「已转交」。已有的零件都在，缺的是把它们接起来：

1. **谁装了什么**：`shared/snapshots/<machineID>.json` 里每个平台有 `detected` 和 `sources`，
   每台机器每 15 分钟写一次。读它就知道对端有没有那个 CLI。**不要新造一份清单。**
2. **machineID ↔ 节点名**：cluster 的 `node.json` 只有节点名（mac-mini / macbook-pro-intel），
   presence 里只有 machineID/machineName。**这两套 ID 现在接不上，是这件事唯一缺的零件**：
   在 `ClusterPresence` 里加一个 `clusterNode` 字段（本机写自己的 nodeName），
   就能从 machineID 查到节点名。加字段要 `decodeIfPresent`（铁律：跨版本传的结构手写解码）。
3. **提交**：复用 `ClusterService .submit(prompt:repo:profile:)`，它已经做了
   别名解析、画像透传、身份校验。派发方本机分诊、带 profile 过去。
4. **本机这条任务的下场**：标 `done` 会让图和统计撒谎。用一个明确的终态：
   `note = "转交 <节点> 执行（本机没有 <平台>）"`，`state = .done`，
   并在 `outputs` 里记下对端返回的 taskID，方便追。**不要留在队列里重派。**
5. **闸门**（一条都不能少）：
   - 只在「本机所有候选都被永久拒绝、且拒绝原因是 CLI 没装」时才考虑转交；
     冷却/额度耗尽这类**不转交**（对端多半也一样，转过去只是换台机器撞墙）。
   - 对端必须在线（presence 新鲜度 < 30 分钟）且 `allowedNodes` 里有它。
   - 对端必须有这个仓库（别名解析在对端做，失败会返回 `failed`，如实记下）。
   - 同一条任务只转交一次（转交过的不再转），防止两台互相踢皮球。
   - 老板的常设指示：碰账号/签名/发布/花钱的任务不转交，按原路走高危闸。

## 验收

- 单测：给一份「本机没有 glm、对端快照里有 glm」的假数据，`decide` 要给出「转交 macbook-pro-intel」
  而不是「没有平台能接」；对端离线时不转交；冷却导致的拒绝不转交；转交过的不重复转交。
- 实跑：在 mini 上派一条点名 GLM 的任务，MacBook 上出现同名任务并跑起来，
  mini 的记录写着「转交 macbook-pro-intel 执行」。
- 手机上：办公室里 MacBook 那台的 ZCode 从「在岗闲着」变成「在跑」。
