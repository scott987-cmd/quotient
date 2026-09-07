from pathlib import Path
import argparse, json, subprocess
p=argparse.ArgumentParser();p.add_argument('--apply', action='store_true');p.add_argument('--release', required=True);a=p.parse_args()
r=Path.home()/'Library/Application Support/LLMQuotaBar';tid='i31c8eb29e2a173f'
rows=[]
for line in (r/'tasks.jsonl').read_text().splitlines():
 try:
  t=json.loads(line)
  if t.get('id')==tid:rows.append(t)
 except ValueError:pass
t=max(rows,key=lambda x:x.get('rev',0))
assert t['rev']==961 and t['state']=='blocked' and t['ownerRunnerID']=='claude.code', 'Task changed; re-review required'
assert not t.get('runnerPID') and not t.get('pausedAt') and not t.get('discardedAt')
assert (r/'installed-release').read_text().strip()==a.release, 'Expected release not installed'
w=r/'worktrees/flint-kimi';base='51e799a650ecc0eab0b84709685fef7d64ee6b56'
def git(*args):return subprocess.check_output(['git','-C',str(w),*args],text=True).strip()
assert git('rev-parse','HEAD')==base and not git('status','--porcelain'), 'Kimi source changed'
s=Path.home()/'.kimi-code/sessions/wd_flint-kimi_1c7ef2f84196/session_26be86f3-c6d1-4a51-845b-5d077ccbb1e8/agents/main/wire.jsonl'
assert s.exists(), 'Original Kimi session missing'
reason="""Codex 已完成真实产物复核及交接机制修复，现恢复原 Kimi Owner 与原会话，完整继承 51e799a（含797f007、00a42fc）；Claude 在旧fa85c9d分支未产生新提交。

【已经给出的架构裁决与下一步，不再等待重复确认】BREAKWATER idle/walk 与已认可样板哈希完全一致，是成功接入；冻结这套已认可的角色外观，不再随意重做衣服和角色造型。此前火力帧03-aim-t20.1-full及04手部裁剪显示左手未握护木、枪托未抵肩、枪管斜指上方，单改prim路径没有解决接触；这些未获认可。现在先用flint-production/flint-studio现成工具检查骨骼、挂点、持枪动作，在独立候选中修正，按相同镜头提供idle/walk/aim/fire前后帧与真实模拟器视频，确认后接入实际消费路径。CombatSlice当前仅替换idle/walk而无fire动作，需核对并补齐其武器与动作整合。

随后检查level-t76s中近景队友遮挡、角色脚底与地面关系及敌人可见性，用实际镜头/坐标验证原因再修，不能只据截图猜尺寸。沿用已授权的模拟器跑通关卡与射击。现有新模型入口多在DEBUG，明确实际可玩路径是否消费；不要把样板页绿色当游戏交付。iPhone11真机暂不可测不阻断可在模拟器完成的工作。当前行动是实作整改及实图证据，不是再写等Codex复验或重复取舍问题；保留原源码、质量历史和原会话，不从main重做，不自行降低门槛。调用work progress记录真实下一步和产物，完成仍需实际画面验收。"""
command=[str(Path.home()/'.local/bin/llmq'),'work','handoff',tid,'kimi','--base',base,'--reason',reason]
print(json.dumps({'verifiedRevision':t['rev'],'base':base,'originalSession':s.parent.parent.parent.name,'apply':a.apply},ensure_ascii=False),flush=True)
if a.apply:subprocess.run(command,cwd=t['repo'],check=True)
