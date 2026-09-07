# Handoff HEAD independent acceptance — complete

Reviewer `/root/independent_model_acceptance`; implementer `/root`. Review performed from actual source, without changing business code, production tasks, Owner, services, or real cloud data. Initial Core HEAD `610f9a244aff9d7ecbb2e64af9dde2123f26b73a`; App HEAD `0e7eccd1ad6e0d3ca3977897585c4c3f335cfacd` unchanged. Initial manifest is `source-fingerprints-initial.json`; final manifest is `source-fingerprints-final.json`.

## Independent review findings and correction

1. **Initial release blocker:** `advanceBranch` returned immediately when the destination already contained the required source commit, bypassing dirty/busy checks. The subsequent `GitWorkspace.prepare` can reset and clean a reused workspace. An equal or leading destination with unsaved work therefore could lose those changes during handoff. Reported to implementer; final candidate now checks an actual checked-out destination before this return. New equal/leading dirty/busy cases were required to reproduce the original failure.
2. **Adjacent consumer safety gap:** a stable platform workspace can be on another task's branch. Checking only the destination ref misses that directory before `prepare` resets/cleans it. Reported to implementer; the resume prepare path now validates its real reusable workspace before any target-ref mutation or prepare call. Same-owner/same-task in-place resumption keeps its existing direct path, preserving its own dirty progress. No broad rewrite of normal dispatch was requested.

Both corrections were read again in final source. The final implementation and affected tests were then verified; see the final evidence below.

Other reviewed boundaries: checkpoint requires successful status, saves dirty content, confirms clean status, and returns actual full HEAD even when no new WIP commit is required. Save failure blocks continuation and does not substitute historical handoff SHA. The scheduler's terminal path preserves blocked state and explanatory note. Branch advancement validates refs and source commit, retains destination commits already containing the base, only fast-forwards ancestors, refuses divergence, and uses expected-old update-ref for unchecked-out branches. Checked-out fast-forward uses merge --ff-only. Unknown refs/status/occupancy fail conservatively. No mobile shared-schema or quota-reserve configuration change is present.

The safety check is point-in-time, not a repository-wide mutual-exclusion protocol: this batch does not promise immunity to arbitrary external mutation after validation. Existing same-owner execution leases are still relied upon. No production long-running stress or multi-Mac handoff was performed by this reviewer.

## Executed current-Core proof

`core-handoff-producer.swift` creates an isolated real Git repository, advances source after an old checkpoint, runs actual WorkHandoff.checkpoint and advanceBranch, verifies the newly committed file at the destination, and publishes the actual TaskBoard/Mirror output. Its displayed running status is a synthetic UI fixture, not a claim that a real Agent was launched. The final phone image shows new source SHA 5de73981 and target Claude as produced by that code.

The separate current-Core playbook flow verifies actual producer → phone action → correct-machine consumer → successful receipt → phone reread, with wrong-machine refusal. All data stays in isolated temporary roots.

## Coverage boundary

Real APNs, physical phone installation, real iCloud propagation, production task restoration and real multi-Mac handoff are not verified by simulator tests. Previous batch identified that the iPad landscape test accepts a 13-inch portrait width and device rotation was not reliable; a green test alone will not be described as proven actual landscape. App source is unchanged in this batch. Final evidence will distinguish existing fixture UI checks from real current-Core-produced data.

## Final independent result

**No remaining blocker from this batch was found. The final server repair may proceed through the authorized release workflow.** Simulator acceptance is not a claim that it has been installed or that production handoff/recovery has happened.

- Full iPhone 15 Pro Max (iOS 26.5; B21093BB-36F9-4E3B-8DBD-2B8BF8051AAB): 103 unit + 32 UI, 133 passed, 0 failed, 2 iPad-only skips. Logs/results: `iphone-full.log`, `iphone-full.xcresult`, `iphone-summary.json`.
- iPad Air 13-inch M4 (iOS 26.5; 866C752A-8D86-4A98-9CAC-EC1E0B02FB9A): related 5 UI tests passed, 0 failed/skipped (`ipad-related.log`, `ipad-related.xcresult`, `ipad-summary.json`). The skipped phone methods `testIPadRailCollaborationOpensTimeline` and `testOfficeShowsTeamDashboardOnWideIPad` both actually ran here. Other related cases cover same-branch different-source actions, tasks/questions without dashboard, and existing-schema next-step block reasons.
- The final business objects were used to rebuild all four helpers. The isolated real handoff producer passed: old 52e7d339013c8f975de46b59fff2108afbf02568 → latest/checkpoint/target 5de739819b98ea873427a9b5d350322016d5fb8d, with the newly committed file readable in the target branch (`handoff-proof-final.json`, `core-handoff-producer-final.log`).
- Final current-Core producer→phone read/write: 2/2 passed (`iphone-final-core-chain.xcresult`). The actual isolated consumer refused the wrong machine and succeeded on the intended machine; final phone receipt reread 1/1 passed (`iphone-final-receipt.xcresult`, `core-playbook-consumer-final.log`). Actual published/mirrored files and receipts are preserved in `actual-chain-cloud-final`. Initial candidate chain evidence is separate and not substituted for the final chain.

### Actual images reviewed

- `iphone-current-core-handoff.jpg`: actual final Core taskboard displayed in the running App. New commit 5de73981, preserved Claude branch, next step, MacBook Pro source and Claude platform are readable and match the Git proof. Missing quota snapshot is expected because this isolated fixture intentionally contains only the taskboard. The fixture's running state does not mean a real model was started.
- `iphone-source-attachments/D8AB2DB4-F90B-4077-8059-0226DFB52BD7.png`: source A is submitted and waiting for its target while source B remains independently actionable; no cross-machine state contamination or button overlap observed.
- `ipad-layout-attachments/975F5C93-EBE2-47FF-9CDE-A3A113B652DD.png`: two machine groups, progress/next step and team panel visible without observed overlap. The attachment is portrait. The test checks width ≥960pt, which this large portrait device also satisfies; it is not proof of actual landscape. This previously identified coverage gap remains explicitly unverified. No mobile layout or orientation source changed in this batch.
- The Mac became locked during final manual capture, so native Save Screen was unavailable. The existing Simulator screenshot interface produced the 369×800 current-Core phone image. Full-resolution XCTest source/layout images remain available. No user unlock was needed for the completed evidence, and no lock bypass was attempted.

### Test-fixture correction and final source binding

The implementer's initial full Core run reported 1560 passed, 2 existing keychain-interaction skips and 1 failed test. That failure was an invalid pre-commit-hook fixture: GitWorkspace deliberately disables hooks, so the hook did not simulate commit failure. The initial affected 24-test run also retained that fixture failure (two assertions). These failures were not hidden or called a clean full run.

The fixture was corrected to use an isolated actual index.lock while retaining rejection/old-HEAD/file-preservation assertions. A controlled mutant ignoring save failure and returning old HEAD failed the corrected test; restored final implementation passed all 7 WorkHandoff cases. The final original related 24-test package also passed 24/24 (`Core qa-reports/2026-09-07-handoff-head/green-verified-final.log`). Those Core results were executed by the implementer, separately from the actual producer/mobile tests executed by this independent reviewer. The initial same/ahead unsafe-return regression was likewise reproduced before correction.

Only `Tests/LLMQuotaCoreTests/WorkHandoffTests.swift` changed after the final producer build, to correct that fixture. Business sources and App contents stayed identical. `test-fixture-only-delta.json` preserves that exact change; the producer-time manifest remains available. Final test file SHA is 1952a38b76b4a7008963b8f4d3d213f5dab04cc52c662549bfe1ea18af5cc277. End-of-run `final-source-recheck.json` reports no changed files against the final manifest.

Final Core Sources+Tests aggregate SHA-256: `bdadd8b6d55d58a4ef8ba3afbcc1c50b9889e35f1bbcc21469783e41a99882be`.
App source/project/tests aggregate SHA-256: `992d691d97952c102031460ed6fbe3510b28bbc578fc0e46802e25ed5548d11d`.
