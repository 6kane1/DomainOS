# Architecture · Архитектура

How Domain OS is put together, for a second maintainer or a reviewer. The threat model is in
[THREATMODEL.md](THREATMODEL.md); test results in [TEST-RESULTS.md](TEST-RESULTS.md).

```
            ┌───────────── GitHub (6kane1/DomainOS) ──────────────┐
 source ──► │ main: playbook/, toolbox/, tests/, tools/, workflows │──► Releases: .apbx + Toolbox .exe (attested)
            │ gh-pages: website + update/ (signed feeds)           │──► https://6kane1.github.io/DomainOS/
            └──────────────────────────────────────────────────────┘
                         │ AME Wizard installs the .apbx                ▲ Toolbox checks the signed feed daily
                         ▼                                              │
   Windows PC ── playbook scripts (as TrustedInstaller/admin) ── %ProgramData%\Domain OS (state for Undo)
             └── Domain OS Toolbox (admin, tray) ── %ProgramData%\Domain OS Toolbox (settings, backups)
```

## 1. Playbook (`playbook/`)
An AME Wizard playbook: `playbook.conf` (options, supported builds) and `Configuration/Tasks/*.yml` (every registry
value, service, scheduled task and app the playbook changes). Scripts in `Executables/`:

| Script | Role |
|---|---|
| `Test-Edition.ps1` | first step: stops on anything but Windows 11 Pro 25H2/26H2, before any change |
| `Save-State.ps1` | before the first change: the original value of everything the task files touch → `%ProgramData%\Domain OS\Undo\state.json` + a never-changed copy `state.original.json` (written via `.tmp`, read back, then swapped) |
| `Install-DomainOS.ps1 -Part …` | the playbook's own steps (Tools: Toolbox, Start menu entries, `undo-allowlist.txt` in Program Files) |
| `Undo-DomainOS.ps1` | puts every saved item back; only items on the allow-list; items only SYSTEM / TrustedInstaller may change go to `Undo-AsSystem.ps1` (one-shot SYSTEM task, removed right after) |
| `Check-DomainOS.ps1` | read-only report: every expected change (`expected.json`, generated from the task files by `tools/gen-expected.py`), Undo readiness incl. a `-WhatIf` dry run, Windows health |
| `DomainOS-Common.ps1` | shared code: file trust (`Test-DomainOSFile`: owner SYSTEM/Administrators/TrustedInstaller, not a link), the allow-list, the strict `.reg` import (`Import-DomainOSRegFile`), the account the playbook runs for |

Rules every script keeps: Windows PowerShell 5.1 syntax; stop on any error; nothing is read from a place a standard
user can change without an owner check; every change has an Undo entry.

`build.sh` runs the whole test suite (`tests/run-all.py`) and refuses to pack on any failure; the `.apbx` is a 7-Zip
archive with AME Wizard's fixed password (and a random salt, so every build has a new SHA-256).

## 2. Toolbox (`toolbox/`, C# / .NET 8 / WPF)
`DomainScheduler.Lib` (logic, tested on Linux with fakes) and `DomainScheduler` (the window, tray, pages).

| Part | What it does |
|---|---|
| `AutoController`, `AutoLogic`, `GameMask`, `Top5`, `Engine` | Auto: detects the game (watchlist, window, graphics module, CPU share), gives it a process mask without the interrupt cores, a priority class, ideal processors for its busiest threads (a hint only; no thread is pinned), mutes the background (priority, I/O, EcoQoS, no affinity). Everything is reverted on exit, on a crash at next start (`session.json`) and by "Undo everything" |
| `Guard` | never opens a game under a kernel anti-cheat, anti-cheat processes or system-critical processes |
| `EtwIrq`, `EtwFrames` | private ETW sessions: live DPC/ISR per processor (interrupt-busy cores), DXGI Present events (frame times) |
| `IrqLayout`, `IrqAuto`, `Devices` | "Optimize devices": interrupt affinity of GPU, USB, network; backup and restore |
| `GpuProfiles`, `NvOc`, `AmdOc`, `BootGuard` | GPU overclock profiles (offsets only, driver-reported limits, AMD voltage only lowered); `BootGuard` detects an unexpected shutdown after an apply; crashed values are remembered (1.16.0) |
| `Updater`, `TesterKey`, `UpdateService` | signed update feeds, SHA-256-checked downloads, sealed test builds, `.prev` copy for rollback |
| `StateDir`, `Settings`, `Store` | the protected data folder `%ProgramData%\Domain OS Toolbox` (owner and ACL checked, repaired), settings in HKLM |
| `CheckTrace`, `CheckStats`, `SelfThreads` | the Check page (one run: frames + ready-thread waits) and the per-thread own load (1.16.0) |

## 3. Updates
- `gh-pages/update/stable.json` + `.sig`: ECDSA P-256 over SHA-256, main key on the author's PC, backup key offline.
  Toolbox accepts a feed signed by any key it knows; every file in the feed is checked by size and SHA-256.
- `update/test.bin` + `.sig`: the test feed, AES-256-GCM-sealed with the tester key, then signed. Test builds are
  sealed the same way (`tools/publish-test-build.py`).
- After an update the previous exe stays as `.prev`; if the new one does not start, it comes back by itself.

## 4. Build, test, release
| Workflow | What |
|---|---|
| `tests.yml` | on every push/PR: Ubuntu `run-all.py` (playbook, Pester, guides, Toolbox `dotnet test`, bot, website + signed feeds, workflows), Windows PowerShell 5.1 + Toolbox tests, a real apply → check → undo on a Windows Server runner (default and all options) |
| `toolbox-build.yml` | builds the Toolbox exe on GitHub's machines and attests it (Sigstore) |
| `apbx-build.yml` | downloads the attested exe, verifies it, runs the suite, packs and attests the `.apbx` |
| `pages.yml`, `discord-*.yml` | website deploy, the Discord bot and status card |

`main` is protected: changes only through a pull request with the four test jobs green, no force-push, also for
administrators. Actions are pinned by commit SHA. Stable releases go out only after test builds soaked with testers.

## 5. Measuring tools (`tools/`, separate releases)
DomainSchedTest (ETW ready-thread waits + frames, `--runs`, `--etl`), DomainFrameTime (live frame-time graph),
DomainAnalyzer (full Windows report). They only read; nothing is changed.

---
Русский кратко: плейбук (AME Wizard) сохраняет исходное состояние до первого изменения и всё возвращает через Undo по
разрешённому списку; Toolbox (C#) ведёт игру и фон без жёсткой привязки потоков и всё откатывает; обновления — только
подписанные фиды с проверкой SHA-256; сборки — на GitHub с аттестацией; `main` защищён (только PR с зелёными тестами).
