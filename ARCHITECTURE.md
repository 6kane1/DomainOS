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

## 2. Toolbox (`toolbox/`, native since 1.17.0: Rust + C++20 / Dear ImGui / DirectX 11)
`core/` is the Rust crate `dos_core` (all the logic, tested on Linux with a fake Windows, built as a static library),
`threadmap/` the Rust crate of the Thread map page (linked into `dos_core`), `app/` the C++20 window, tray and pages on
Dear ImGui + DirectX 11 + Win32, which only draws and calls the core through its C ABI (`core/src/ffi`,
`app/src/dos_core.h`). `toolbox/build.sh` cross-builds one static `DomainScheduler.exe` (about 8 MB) on Linux. The exe
name, install folder, scheduled task, registry settings, state folder, command-line switches and update keys are those
of the C# / .NET 8 / WPF Toolbox up to 1.16.x, which it replaces.

| Part (`toolbox/core/src/…`) | What it does |
|---|---|
| `auto/controller`, `engine/auto_logic`, `topo/game_mask`, `auto/top5`, `engine/engine` | Auto: detects the game (watchlist, window, graphics module, CPU share), gives it a process mask without the interrupt cores, a priority class, ideal processors for its busiest threads (a hint only; no thread is pinned), mutes the background (priority, I/O, EcoQoS, no affinity). Everything is reverted on exit, on a crash at next start (`session.json`) and by "Undo everything" |
| `engine/guard` | never opens a game under a kernel anti-cheat, anti-cheat processes or system-critical processes |
| `etw/irq`, `etw/frames` | private ETW sessions: live DPC/ISR per processor (interrupt-busy cores), DXGI Present events (frame times) |
| `topo/irq_layout`, `etw/irq_auto`, `system/devices` | "Optimize devices": interrupt affinity of GPU, USB, network; backup and restore |
| `gpu/profiles`, `gpu/nv_oc`, `gpu/amd_oc`, `system/boot_guard` | GPU overclock profiles (offsets only, driver-reported limits, AMD voltage only lowered); the boot guard detects an unexpected shutdown after an apply; crashed values are remembered (1.16.0) |
| `system/updater` (incl. `TesterKey`), `ffi/update_service` | signed update feeds, SHA-256-checked downloads, sealed test builds, `.prev` copy for rollback |
| `base/state_dir`, `base/settings`, `system/store` | the protected data folder `%ProgramData%\Domain OS Toolbox` (owner and ACL checked, repaired), settings in HKLM |
| `etw/check_trace`, `auto/check_stats`, `native/self_threads` | the Check page (one run: frames + ready-thread waits) and the per-thread own load (1.16.0) |
| `etw/thread_map`, `threadmap/` | the Thread map page (1.17.0): the game's processes and threads as a live graph over 30 s; its kernel trace runs only while the page is open |

## 3. Updates
- `gh-pages/update/stable-native.json` + `.sig`: the feed of the native Toolbox (1.17.0+). ECDSA P-256 over SHA-256,
  main key on the author's PC, backup key offline. Toolbox accepts a feed signed by any key it knows; every file in the
  feed is checked by size and SHA-256.
- `update/test-native.bin` + `.sig`: its test feed, AES-256-GCM-sealed with the tester key, then signed. Test builds
  are sealed the same way (`tools/publish-test-build.py`).
- `update/stable.json` and `update/test.bin`: the feeds the C# Toolbox 1.16.x reads, signed with the same keys;
  `stable.json` keeps the 1.16.1 entry. The C# Toolbox is not moved to the native one through the feed: it shows that
  playbook 2.3.2 is out, and the native Toolbox comes with that playbook (AME Wizard over Domain OS).
- After an update the previous exe stays as `.prev`; if the new one does not start, it comes back by itself.

## 4. Build, test, release
| Workflow | What |
|---|---|
| `tests.yml` | on every push/PR: Ubuntu `run-all.py` (playbook, Pester, guides, Toolbox `cargo test`, bot, website + signed feeds, workflows), Windows PowerShell 5.1 + Toolbox `cargo test` on Windows, a real apply → check → undo on a Windows Server runner (default and all options) |
| `toolbox-build.yml` | cross-builds the Toolbox exe on ubuntu-latest with the pinned toolchain (`.github/actions/native-toolchain`, llvm-mingw checked by SHA-256, `cargo --locked`, `--remap-path-prefix`), attests it (Sigstore) and an SPDX SBOM (`tools/make-sbom-native.py`) |
| `apbx-build.yml` | downloads the attested exe, verifies it, runs the suite, packs and attests the `.apbx` |
| `pages.yml`, `discord-*.yml` | website deploy, the Discord bot and status card |

`main` is protected: changes only through a pull request with the four test jobs green, no force-push, also for
administrators. Actions are pinned by commit SHA. Stable releases go out only after test builds soaked with testers.

## 5. Measuring tools (`tools/`, separate releases)
DomainSchedTest (ETW ready-thread waits + frames, `--runs`, `--etl`), DomainFrameTime (live frame-time graph),
DomainAnalyzer (full Windows report). They only read; nothing is changed.

---
Русский кратко: плейбук (AME Wizard) сохраняет исходное состояние до первого изменения и всё возвращает через Undo по
разрешённому списку; Toolbox (с 1.17.0 нативный: ядро на Rust, окно на C++ / Dear ImGui) ведёт игру и фон без жёсткой привязки потоков и всё откатывает; обновления — только
подписанные фиды с проверкой SHA-256; сборки — на GitHub с аттестацией; `main` защищён (только PR с зелёными тестами).
