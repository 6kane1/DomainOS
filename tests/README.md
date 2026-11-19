# Automatic tests (tests/run-all.py)

One program checks the whole project and ends with PASS / FAIL (exit code 0 / 1). `build.sh` runs it before packing and
refuses to build on any failure, then checks the packed archive (area I) and deletes it if it is broken.
`./build.sh --skip-tests` packs without tests: only for an emergency re-pack of sources that already passed.

    python3 tests/run-all.py              # everything, about 30-40 s (+ the first dotnet restore)
    python3 tests/run-all.py -v           # also list every passing test
    python3 tests/run-all.py --only A,B,D # some areas

Areas: A playbook.conf, B YAML task files (AME schema + safety rules), C Undo consistency, D PowerShell static analysis
(PS 5.1 compatibility, BOM, $null into .NET, %USERNAME%), E Pester tests that RUN Save-State / Undo / Undo-AsSystem /
Install-DomainOS in a sandbox with a fake registry, F guide pages in node, G Toolbox `dotnet test`, H Discord bot,
I built .apbx, J website + signed update feeds, K DomainSchedTest, L GitHub workflows + status card.
Needs python3 (PyYAML, cryptography, Pillow), PowerShell 7 (~/sdk/pwsh or DOS_PWSH), the .NET 8 SDK, node and 7zr.
Pester 5.7.1 is kept in tests/.vendor, so nothing is downloaded. No test uses the network or a token.
Files: lib/ (runner, AME model, areas), ps/ (AST analysis, item list, guide generator), pester/ (Harness.ps1 = the
Windows stand-ins, *.Tests.ps1), js/run-page.js (pages with a small DOM).

# Measuring Domain OS (WPR / WPA)

A playbook is worth publishing only with numbers. This kit records the same data the same way on any Windows, so
"stock" and "Domain OS" (or another build) can be compared on one PC.

## Rules for a fair comparison
1. **Same PC, same Windows build, same drivers, same BIOS settings.** Install stock Windows 11 25H2, all updates, all drivers — measure. Apply the playbook — measure again.
2. **Three runs of each**, compare the typical one. One run proves nothing.
3. **Idle:** at least 10 minutes after start-up, no windows open, network connected, nothing touched during the recording.
4. **Game:** the same scene every time (a demo, a benchmark map, a replay). Record 1% low / 0.1% low / p99 with CapFrameX in the same runs.
5. **Report everything**, including results where nothing changed or it got worse.

## Recording
Run PowerShell as administrator in this folder:

```
.\Measure-DomainOS.ps1 -Label stock    -Scenario Idle -Seconds 120
.\Measure-DomainOS.ps1 -Label stock    -Scenario Game -Seconds 120
.\Measure-DomainOS.ps1 -Label stock    -Scenario Boot
... apply the playbook, install the same drivers ...
.\Measure-DomainOS.ps1 -Label domainos -Scenario Idle -Seconds 120
.\Measure-DomainOS.ps1 -Label domainos -Scenario Game -Seconds 120
.\Measure-DomainOS.ps1 -Label domainos -Scenario Boot
.\Compare-Snapshots.ps1 .\results\stock-Idle-<time> .\results\domainos-Idle-<time>
```

`wpr.exe` is part of Windows. The analyzer (WPA) and `xperf.exe` come with the Windows Performance Toolkit from the
Windows ADK; with it installed the script also writes `dpcisr.txt` and `cpu-by-process.txt`.

## What to compare in Windows Performance Analyzer

| Question | Graph in WPA | What to read |
|---|---|---|
| How much does the system do when nobody uses it? | **Computation → CPU Usage (Sampled)**, grouped by Process | Total weight (%) outside "Idle"; the top processes. Fewer and lighter is better. |
| Who interrupts the game? | **Computation → DPC/ISR → Duration by Module, Function** | Total duration per driver and the longest single DPC/ISR. A long tail (over 0.5 ms) on a network or graphics driver matters more than the sum. |
| Do the game's threads wait for a core? | **Computation → CPU Usage (Precise)**, columns New Process, New Thread ID, Ready (µs), Waits (µs) | Sum and maximum of *Ready* time for the game's main and render threads. Lower is better; this is what DomainScheduler is supposed to improve. |
| Do the game's threads move between cores? | CPU Usage (Precise), columns New Thread ID, CPU, Count | How many different CPUs the main thread ran on and how often it switched. |
| What reads and writes the disk in the background? | **Storage → Disk Usage → Utilization by Process, Path** | Processes other than the game during the Game trace. |
| How long does Windows take to start? | Boot trace: **System Activity → Boot Phases** (or Regions of Interest → FullBoot.Boot.wpaProfile) | Total boot time and the Post Boot phase. |

## What counts as a result
- A difference of a few percent between single runs is noise. Call it a result only when the three runs of one setup do not overlap with the three runs of the other.
- Process count, services and memory after start-up should clearly go down with Domain OS — that is what the playbook does.
- Frame-time numbers and Ready time may not change at all, or only with DomainScheduler turned on. Say so if that is what you measure.


---

# Win32PrioritySeparation A/B: 0x18 vs 0x26 (DomainSchedTest)

`Compare-PrioritySeparation.ps1` changes only `HKLM\SYSTEM\CurrentControlSet\Control\PriorityControl\Win32PrioritySeparation`.
Before the first change it writes the current value to `PrioritySeparation-original.txt` next to itself; `-Restore` writes
exactly that value back (or deletes the value if there was none) and removes the file. It asks for administrator rights
(UAC) only for `-Set` / `-Restore`. The value takes effect at once; the plan still restarts the PC at every switch, with
10 minutes idle, so both variants start from the same state.

```powershell
.\Compare-PrioritySeparation.ps1                # current value, recorded original, the measuring plan
.\Compare-PrioritySeparation.ps1 -Set 0x18      # variant A (Domain OS)
.\Compare-PrioritySeparation.ps1 -Set 0x26      # variant B
.\Compare-PrioritySeparation.ps1 -Restore       # back to the recorded original
python compare_runs.py C:\PS-Test --groups ps18,ps26
```

Order of the six 60-second CS2 runs (labels ps18-1..3, ps26-1..3): A | B B | A A | B, a restart before each block.
`compare_runs.py` reads every `summary.txt`, groups by label without the run number, takes the same number of runs per
group (the first ones by date), and calls a difference real only when the min..max ranges do not overlap and the
difference of the means is larger than the wider range; otherwise it prints "нет измеримой разницы".

---

# Замеры Domain OS (WPR / WPA) — кратко

1. Один и тот же ПК, одна сборка Windows, одни драйверы. Сначала чистая Windows 11 25H2 со всеми обновлениями и драйверами — замер. Потом плейбук — замер.
2. По три прогона каждого сценария; сравнивать типичный.
3. Простой: не раньше чем через 10 минут после загрузки, окна закрыты, мышь не трогать.
4. Игра: одна и та же сцена; в тех же прогонах записывать 1% low / 0.1% low / p99 в CapFrameX.
5. Публиковать всё, включая «ничего не изменилось».

Команды — в блоке выше (PowerShell от имени администратора). `wpr.exe` есть в Windows; анализатор WPA и `xperf.exe` ставятся из Windows ADK (Windows Performance Toolkit).

В WPA смотреть: CPU Usage (Sampled) по процессам в простое; DPC/ISR по модулям (сумма и самый длинный); CPU Usage (Precise) — время Ready у главного и рендер-потока игры и по скольким ядрам они гуляли; Disk Usage по процессам; для загрузки — Boot Phases.
