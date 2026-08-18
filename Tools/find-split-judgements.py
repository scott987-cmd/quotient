#!/usr/bin/env python3
"""找「同一个概念在多处独立判定」—— 这套代码里最贵的那类 bug。

2026-08-18 一天之内，同一个形状害了**八次**：

  · 上游让开了吗       4 个判定点（isReady / blocker / briefing / stranded）
  · 冻结说明           写入时机有、刷新没有
  · 排队集合           autoland 的 guard 有、队列没有
  · 任务类型前缀       4 种写法（【评审 /【审查】/【审查·合入】/【媒体】）
  · reviewOnly         协议没声明，扩展默认值永远赢
  · 在飞守卫           release publish 有、build-app.sh 没有
  · 要不要 agent 审核  autoland 有、派发端没有
  · 媒体前缀           TaskKind 判「【媒体」、TaskIntake 判「【媒体】」

每一次的形状都一样：**改了一处判定，忘了另一处**。
每一次的后果都是静默的 —— 没有报错，只是某件事永远不发生：
任务看得见却永不执行、审核永远不派、闸从来没关上过。

靠人记住是不够的，那一天已经证明了。所以做成一条能跑的检查。

    python3 Tools/find-split-judgements.py

它只**提示**，不判对错 —— 同一个字段在多处出现有时是正当的
（显示层和判定层各读一次）。它的价值是让你**每次都看一眼**，
而不是等某件事永远不发生之后再回来查。
"""
import re
import pathlib
import collections

# 每一条都对应一次真实事故 —— 加新条目时也请写清它挡的是什么。
PATTERNS = {
    "manualReview（要不要人看效果）": r"\.manualReview",
    "discardedAt（处置过了吗）": r"discardedAt\s*[!=]=",
    "reviewOnly（评审专用执行器）": r"\.reviewOnly",
    "任务类型前缀（【媒体】/【评审】…）": r'hasPrefix\("【',
    "mergesCleanly（合得进去吗）": r"\.mergesCleanly",
    "state == .done（算干完了吗）": r"state\s*==\s*\.done",
    "changedFiles（有没有产出）": r"changedFiles",
}


def main() -> None:
    src = list(pathlib.Path("Sources").rglob("*.swift"))
    if not src:
        print("在仓库根目录跑我（找不到 Sources/）")
        return
    print("同一概念的判定点分布 —— 分布在多个文件就值得看一眼是不是该收口：\n")
    for name, pat in PATTERNS.items():
        hits = collections.Counter()
        for f in src:
            n = len(re.findall(pat, f.read_text(encoding="utf-8")))
            if n:
                hits[f.name] = n
        if len(hits) > 1:
            print(f"  {name}: {sum(hits.values())} 处 / {len(hits)} 个文件")
            for fn, n in hits.most_common(5):
                print(f"      {fn}: {n}")
            print()


if __name__ == "__main__":
    main()
