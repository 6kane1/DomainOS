# Test results · Результаты тестов

All real-PC results so far come from **one PC**: AMD Ryzen 7 7800X3D, NVIDIA RTX 5060, NVMe SSD, Windows 11 Pro 26H2
(build 26300). Benchmarks were taken with the project's own tracer (ETW: frame times from DXGI Present events, ready
thread → context switch wait times). Groups always have the same number of runs (extra runs: the first N by time).
Domain OS does not change VBS, memory integrity or the CPU's virtualization; measurements of those are not published here.

Все результаты на реальном ПК пока получены на **одном ПК** (выше). Замеры — собственным трассировщиком проекта
(ETW). В группах всегда одинаковое число прогонов.

## 1. Build-time suite · Автотесты при сборке (`python3 tests/run-all.py`)

| Area | Checks | Result |
|---|---|---|
| A playbook.conf | 14 | pass |
| B YAML tasks (schema, options, safety rules + self-tests) | 21 | pass |
| C Undo consistency | 9 | pass |
| D PowerShell static (5.1 compat, BOM, `$null`→.NET, `-cmatch` for FAILED) | 30 | pass |
| E Pester: Save-State, Undo, Undo-AsSystem, Install run in a sandbox | 72 | pass |
| F Guide pages (node, both languages) | 9 | pass |
| G Toolbox `dotnet test` (227 unit tests) | 2 | pass |
| H Discord bot | 9 | pass |
| I built `.apbx` contents | checked after packing | pass |
| J Website + signed update feeds | 56 | pass |
| K DomainSchedTest | 4 | pass (1 info) |
| L GitHub workflows + status card | 22 | pass |
| **Total** | **248** | **PASS** |

Bugs this suite found and that were fixed: per-user backup folders named after the computer account (Undo did not find
taskbar/Start pins and wallpapers); an install guard that could never fire; missing UTF-8 BOMs; a `-match` that read
Undo's summary "Failed: 0" as a failure.

## 2. Install on a real PC · Установка на реальном ПК

| Build | What happened | Fix |
|---|---|---|
| 2.1.3 | stopped at "Saving the current state": files saved by older versions under the user's admin account were refused | 2.1.4: files of administrator accounts accepted and handed to Administrators |
| 2.1.4 | "The path is not of a legal form": `File.Replace(…, $null)` — PowerShell passes "" | 2.1.5: `[NullString]::Value` |
| 2.1.6 | What's new / driver guide did not open: HKCU RunOnce under AME's SYSTEM environment | 2.1.7: logon scheduled task for Users; 2.1.8: no console flash (`conhost --headless`) |
| 2.1.9 | the new final check stopped the install: 10 `ContentDeliveryManager` values were gone 30 s after being written (Windows rewrites that key) | 2.1.10: those values warn instead of fail |
| **2.1.11** | installed on the owner's PC and used for the 0x18/0x26 runs; the full Check Domain OS report for 2.1.11 is still to come | released unchanged in code as **2.2.0** (19.11.2026) |
| **2.2.0** (stable) | installed over 2.1.11 on 19.11.2026; install check at the end: 0 FAIL, 10 WARN, 188 PASS | — |

**Check Domain OS on 2.2.0** (19.11.2026, 17 options incl. the opt-in UAC no-prompt): **0 FAIL**, 220 PASS, 1 SKIP (the old
Appraiser task does not exist on 26H2), 11 WARN: 10 × ContentDeliveryManager values that Windows itself deletes or resets
after the install (marked `[check: warn]` by design) and 1 unexpected shutdown (Kernel-Power 41 at 18:10, before the
2.2.0 install). Undo ready: state from the first install (16.11) readable in both copies, allow-list covers every item,
`Undo -WhatIf` 208 changes and 0 skipped. Data folder ACL as designed. Windows health: DISM Healthy, `sfc /verifyonly`
clean, no device errors, Windows Update working, disk healthy. Event-log errors come from third-party vendor services,
the hypervisor configuration, and 13 × Downloaded Maps Manager (7023) in 24 h — still to confirm
that they all predate the on-demand start type (MapsBroker is 3 = manual now, as expected).

**Check Domain OS on 2.1.9** (the fixes above should turn the failures into pass/warn; not yet confirmed by a 2.1.11 report): 218 PASS, 11 FAIL (10 × ContentDeliveryManager,
1 false alarm in the checker itself — fixed), 1 SKIP (the old Appraiser task does not exist on 26H2), Windows health:
DISM Healthy, `sfc /verifyonly` no violations, no device errors, disk healthy, Windows Update working.

## 3. Measurements · Замеры

### 3.1 Win32PrioritySeparation 0x18 vs 0x26 · 0x18 против 0x26
CS2, empty map without bots, the same spot (`setpos`), 60 s runs, variants alternated with a restart and 10 min idle;
2 runs per variant (tool: `tests/compare_runs.py` — a difference counts only if larger than the run-to-run spread).

| | 0x18 | 0x26 |
|---|---|---|
| FPS | 874 (874–875) | 874 (874–874) |
| 1 % low | 535 (533–536) | 533 (529–538) |
| 0.1 % low | 501 (500–502) | 498 (488–507) |
| frame p99 | 1.87 ms | 1.88 ms |

**No measurable difference.** The playbook keeps 0x18 on the strength of external measurements (0x18 + Game Mode).

### 3.2 Event log after the install · Журнал событий после установки
48 starts and 48 clean shutdowns over 3 days, no Kernel-Power 41 from Domain OS, no BugCheck, no disk or WHEA errors.
Remaining errors came from third-party software (vendor tuning/RGB services) and from the firmware's virtualization
settings — not from Domain OS. The Downloaded Maps Manager error at every boot (Maps app removed) is fixed in 2.1.10.

### 3.3 Toolbox self-update · Самообновление Toolbox
On the owner's PC: **Test 1.7 → 1.15.0 (stable) via Update — works** (19.11.2026, with the key-rotation code; the stable feed is signed with the main key).

### 3.4 Full install → Undo → reinstall on a real PC · Полный цикл на реальном ПК (19.11.2026)
The first real Undo after 2.2.0 found four bugs that the sandbox and the Server 2025 round trip could not see. All
four were fixed in test builds 2.2.1–2.2.3; the CI now has tests for them (PowerShell 5.1 Pester, wallpaper wrapper).

| Build | Found | Fix |
|---|---|---|
| 2.2.0 (stable) | Windows PowerShell 5.1 `ConvertFrom-Json` hands a JSON array over as ONE object: the SYSTEM step of Undo failed for every item when 2+ protected services/tasks were sent (found by the new 5.1 CI job) | 2.2.1: results enumerated |
| 2.2.1 | Undo could not remove `HKLM\…\CurrentVersion\Communications\ConfigureChatAutoInstall` (key owned by TrustedInstaller); the taskbar pin order failed (`REG_BINARY` from the saved .reg export handed to `SetValue` as `object[]`) | 2.2.2: access-denied HKLM values go to the SYSTEM step (backup/restore privilege); byte arrays kept typed |
| 2.2.2 | install stopped at the wallpapers: PowerShell cannot call `IDesktopWallpaper` methods on the raw COM object (first-time save path, never run before) | 2.2.3: calls through static C# helpers; CI smoke test on real Windows |

**2.2.3, the full cycle on the owner's PC** (released unchanged in code as stable **2.2.4**, archive built and attested by `apbx-build.yml`):
1. install over the halted 2.2.2 → Check Domain OS **0 FAIL**, 220 PASS (11 WARN: 10 × ContentDeliveryManager, 1 old unexpected shutdown);
2. Undo → **Restored: 164 items. Failed: 0** (the Communications value and a protected task restored as SYSTEM, taskbar pins, wallpapers, Start pins, power plan, OneDrive);
3. `tests/Verify-Undo.ps1` (compares every saved original value, service and task with the PC): **190 back as before, 3 different, 1 skipped** — the 3 are Windows' own: `GameDVR_Enabled` (rewritten by Windows), a ContentDeliveryManager value, and the wallpaper path (a Windows Spotlight picture comes back as a static picture);
4. Check after Undo: "Domain OS was undone", Windows health all PASS (DISM, sfc, devices, Windows Update, disk);
5. reinstall 2.2.3 → Check **0 FAIL**, 220 PASS.

### 3.5 GPU overclock on/off, CS2 deathmatch with bots · Разгон видеокарты, CS2 DM с ботами (20.11.2026)
Toolbox 1.15.0 Auto in both; 3 runs × 30 s per variant. The overclock (+105 MHz core, +1500 MHz memory) had crashed Windows
once the day before (Kernel-Power 41; Toolbox's crash guard skipped it at the next start, then it was marked again by hand).

| | overclock on | off |
|---|---|---|
| FPS | 766 (729–826) | 734 (728–740) |
| 1 % low | 439 (421–458) | 432 (427–441) |
| 0.1 % low | 244 (206–291) | 218 (199–254) |
| frame p99 | 2.28 ms (2.18–2.38) | 2.31 ms (2.27–2.34) |
| hitches | 58 (27–91) | 50 (42–58) |
| longest frame | 9.0–11.4 ms | **8.3–9.4 ms** |

Without the overclock the runs are steadier (narrower ranges, shorter worst frames) at about 4 % less FPS. Toolbox
1.16.0 remembers values that crashed Windows and asks before they go back on the start.

### 3.6 Two ways of recording give the same numbers · Два способа записи дают одни цифры (20.11.2026)
The same deathmatch, 3 recordings with Windows Performance Recorder's built-in "GPU activity" + "Video glitches" profiles
(read by `DomainSchedTest --etl`) and 3 runs of the project's own lighter trace, alternated:

| | WPR GPU + Video | own trace |
|---|---|---|
| lost events / buffers | 0 / 0 | 0 |
| all threads, wait p50 / p99 | 1.9 / 4.1 µs | 1.9 / 4.2 µs |
| cs2 threads, wait p99 | 3.9 µs | 4.1–4.2 µs |

The heavy recording itself costs about 90 FPS and adds ~100 ms frames at its start and stop; the wait numbers agree.

### 3.7 Where the 1–2 ms waits of cs2 come from · Откуда ожидания cs2 по 1–2 мс (20.11.2026)
In heavy deathmatch moments cs2's own low-priority worker threads (priority 2) wait up to ~2 ms behind cs2's busier
threads inside the game's cores (with Toolbox Auto: 12 of 16 logical processors, the graphics-driver cores left out).
Without Toolbox the same waits stay under ~0.6 ms, but the frames are worse (1 % low 401 vs 439, 76 vs 58 hitches,
3 runs each). Only 8 of 50 hitches in a run had such a wait inside the frame. Next: an A/B on a repeatable demo
(the same 30 s every run) instead of live deathmatch.

## 4. Not tested yet · Ещё не проверено
- Other PCs (Intel, other GPUs, laptops); clean installs on 25H2.
- AMD Radeon overclocking on real cards.
- The Toolbox Check page (1.16.0 Test 1) and `DomainSchedTest --runs` on other PCs.
