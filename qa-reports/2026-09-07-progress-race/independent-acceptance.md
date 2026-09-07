# Progress race / stage-loop independent acceptance — complete

Independent reviewer: `/root/independent_model_acceptance`; implementer: `/root`. The reviewer changed no business source, task, Owner, production process, or real cloud data. App HEAD `0e7eccd1ad6e0d3ca3977897585c4c3f335cfacd`; Core base HEAD `19221e0136005e87132fdb515dbb1fdca8fa2a50` plus frozen WorkProgress/StageFindingLoop changes. Full file manifest in `source-fingerprints.json`.

## Independent code review

The stable sidecar flock is held around re-read, sequence allocation, inheritance, encode and atomic file replacement. The per-path NSLock also serializes threads in one process. File-open / flock / write failure paths unwind the lock, and EINTR is retried. Automatic updates inherit the latest declaration and declaration metadata; explicit clearing remains cleared. updatedAt cannot regress relative to persisted prior state. The controlled subprocess test pauses before committing, writes a newer declaration or clears it, then releases the delayed writer; this is a meaningful reproduction of the lost-update failure. Four subprocess writers and eight thread writers check sequence preservation; forced write failure checks lock release.

Git fingerprint work normally runs before acquiring the lock. If another writer changes evidence during inspection, the evidence fingerprint is intentionally recomputed under the lock. Therefore the implementation does not guarantee zero Git work while locked. This is a bounded performance limitation, not a newly observed functional defect. The process-local lock dictionary retains entries for encountered task paths; no production memory growth measurement was performed.

Initial StageFindingLoop cached HEAD across history screening and later finding publication. During testing the implementer identified that a new source commit between those two decision phases could let an obsolete architect answer be published as current. Independent review agrees this is a real safety-semantic regression. The final correction retains caching for historical screening but probes again at publication. Final Core objects were rebuilt and the real producer contract was retested after that correction; the unchanged App full regression remained valid. No shared-protocol or quota configuration change is present.

## Current Core producer contract

All three helpers were relinked against this batch's current debug Core objects, not reused binaries. `core-taskboard-producer.swift` runs WorkProgressStore.record, WorkContinuationGate, TaskBoard.build, TaskBoardStore.publish and MirrorService.sync in isolated paths. `continuation-proof.json` and `current-core-taskboard.json` preserve results.

Important distinction: the mobile task board publishes progress.nextStep, not explicitNextStep or ordinary queued task.note. The manual record displays the new declared work; the automatic record displays its own “继续当前任务”. Its separately preserved explicitNextStep still causes done→queued through WorkContinuationGate. The mobile image must not be described as exposing hidden explicitNextStep metadata.

The helper initially compared an in-memory timestamp retaining fractional seconds against ISO8601 persisted whole seconds and failed. It now compares against the immediately reloaded persisted baseline, preserving the no-regression check; see `helper-initial-failure.txt`. This was a QA helper correction, not a business or XCTest change.

## Boundaries

All producer/consumer and UI fixture data are synthetic isolated acceptance records produced by the actual Core code. They are not production task state. Real APNs, physical iPhone installation, real iCloud propagation and real multi-Mac restoration are not verified by these simulator tests. Deployment belongs to the implementer and is not implied by this report.

## Final independent result

**No remaining blocker from this batch was found. The final server repair may proceed to the authorized release workflow, subject to the implementer’s final build/deployment checks. This is not a claim of installation, production recovery or universal freedom from stalls.**

- iPhone 15 Pro Max, iOS 26.5, B21093BB-36F9-4E3B-8DBD-2B8BF8051AAB: full 103 unit + 32 UI = 133 passed, 0 failed, 2 iPad-only skipped. `iphone-full.log`, `iphone-full.xcresult`, `iphone-summary.json`.
- iPad Air 13-inch (M4), iOS 26.5, 866C752A-8D86-4A98-9CAC-EC1E0B02FB9A: related 5 UI tests passed, 0 failed/skipped. Both iPad-only phone skips actually executed. Covers navigation to collaboration, team dashboard, same-branch different-machine actions, task/question entry without dashboard and old-schema next-step block reason. `ipad-related.log`, `ipad-related.xcresult`, `ipad-summary.json`.
- After the final StageFinding correction, all three producer/consumer helpers were relinked from final Core objects. Actual producer→mobile read/write: 2/2 passed (`iphone-final-core-chain.xcresult`); wrong machine refused and intended machine succeeded in the real isolated consumer; mobile success-receipt reread: 1/1 passed (`iphone-final-receipt.xcresult`). `actual-chain-cloud-final` preserves the actual mirror payloads and receipts. The final WorkProgress continuation producer assertions also passed.
- Full iPhone/iPad App tests used unchanged App source. The initial Core chain is archived separately and is not substituted for the final Core chain. The final content manifest is `source-fingerprints.json`; the initial manifest is `source-fingerprints-initial.json`. End-of-run recheck found no changed files in either App or final Core (`final-source-recheck.json`).

### Images actually reviewed

1. `iphone-current-core-next-step.png` is a full-resolution original Simulator Save Screen of the final actual Core taskboard fixture. The manual milestone, declared next step, MacBook Pro source and Kimi ownership are readable; one running and one queued task are distinct. The fixture intentionally contains no quota dashboard, so the missing-snapshot warning is expected. The app is displaying the manual progress.nextStep; do not describe it as rendering automatic explicitNextStep metadata.
2. `iphone-source-attachments/9D9ED902-3D3A-43FC-89BF-638AD47A17B0.png`: submitted MacBook Pro A waits for target acknowledgment while Mac mini B remains independently actionable; no accidental cross-machine disable/submit was seen.
3. `ipad-layout-attachments/FAEE9DBA-2AD5-4A88-B450-3168B3162A24.png`: both machine groups and team control panel are visible, with readable progress and next step, and no observed overlap.

### Explicit remaining coverage gap

The existing iPad test named “wide/landscape” only requires window width ≥960 pt. A 13-inch portrait window also satisfies it, and its exported screenshot is portrait. Therefore its green result does **not** prove actual landscape. Manual Simulator rotation and an explicit Device→Orientation→Landscape Left setting left both this app and the iPad system home screen sideways; the environment was restored to normal portrait. No mobile source or orientation setting in the project changed in this batch. Actual landscape remains unverified; this is an existing test/environment coverage gap, not evidence of a server-fix regression. No test was weakened to pass it.

### Final code review boundary

The final StageFinding publication stage calls branchHeadProbe freshly instead of reusing history-screening cache. Independent inspection confirms the unsafe reuse was removed. The implementer’s controlled advancing-HEAD test failed four assertions on the initial candidate; final affected StageFinding suite reports 21/21 passed. Those are implementer Core test results, distinct from the mobile runs executed by this reviewer. Core full suite 1554 passed / 2 existing keychain-interaction skips belongs to the earlier same-batch candidate, with the final affected suite covering the one-line semantic correction; it is not misrepresented as a second full final Core run.


Final Core Sources+Tests aggregate SHA-256: `ef0326f7ac5c16240b9a8b20e5c6420be525feb507bb25f09c67d7b36c0ad4ab`.
App source/project/tests aggregate SHA-256: `992d691d97952c102031460ed6fbe3510b28bbc578fc0e46802e25ed5548d11d`.

Release commit binding: `a693cd94cc88208d52ffc1ef761272b82a12e8ec`, verified identical final tested Core contents (`commit-binding.json`). `ipad-current-core-next-step.png` also preserves the final actual Core taskboard displayed on iPad in portrait.
