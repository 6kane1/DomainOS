# Domain OS

[![Tests](https://github.com/6kane1/DomainOS/actions/workflows/tests.yml/badge.svg?branch=main)](https://github.com/6kane1/DomainOS/actions/workflows/tests.yml)

**English** | [Русский](README.ru.md)

A playbook for [AME Wizard](https://ameliorated.io) that prepares **Windows 11 25H2 and 26H2 (builds 26200, 26300), Pro only**, for games. On Home and other editions the install stops at the first step, before any change.

> **25H2 and 26H2 since 2.1.0.** 24H2 is no longer supported: its security updates have ended. "Hold Windows on 26H2" keeps the system on 26H2 (supported until October 2028) — a PC on 25H2 gets the 26H2 update first.

**A short list of changes, each one explained and checkable.** Every value below names the registry key, service or setting it changes.

> **Before you start**
> - **It can be undone without reinstalling Windows** (see [Undo](#undo)). Removed apps are not reinstalled automatically: Undo lists them for you to install from the Microsoft Store (the Store itself comes back automatically if it was removed). Still, try it in a virtual machine first.
> - **Average FPS does not go up** because of a playbook. What you get is fewer background processes, no advertising, no forced restarts and a system that is set up the same way every time.
> - Domain OS is young. Version 2.3.0 went through test builds and an automatic check of every change, but real PCs differ: report what breaks.

## What stays untouched — on purpose

| Component | Why it stays |
|---|---|
| Microsoft Defender, SmartScreen, Windows Security | Removing them leaves the PC unprotected and breaks anti-cheats. |
| Secure Boot, TPM, VBS, memory integrity, kernel mitigations | FACEIT, Vanguard, EasyAntiCheat and BattlEye check them. |
| Security and quality updates, Defender definitions | A system without them is unsafe within weeks. |
| Xbox Identity Provider, Gaming Services, the Game Bar app | Games sign in and save through them. The Game Bar overlay is off, but the app is not removed. |
| Microsoft Store, App Installer (winget), Edge, WebView2 | Launchers and many programs need them. The Store stays even with the "Maximum" option (since 2.3.0). |
| Core Windows services | Only services with no use on a gaming PC are disabled, each one named and explained. Blind mass disabling breaks features. |

## Supported versions of Windows

| Version | Build | Security updates from Microsoft (Pro) |
|---|---|---|
| 26H2 | 26300 | until October 2028 |
| 25H2 | 26200 | until October 2027 |
| 24H2 | 26100 | ended in October 2026 — **not supported** since 2.1.0 |

Dates are from [Microsoft's lifecycle page](https://learn.microsoft.com/lifecycle/products/windows-11-home-and-pro). The playbook does not switch security updates off on any version. AME Wizard refuses to run it on builds other than 26200 and 26300.

The playbook was run on 25H2 and 26H2. On 25H2 Windows offers the 26H2 update: it is an ordinary update and does not break the playbook.

## What Domain OS changes

Every item can be found in `playbook/Configuration/Tasks/*.yml` with a comment next to it.

### Preinstalled apps (option, on by default)
Removes apps that advertise or start in the background: Clipchamp, News, Weather, Bing search, Solitaire, Teams, Copilot app, new Outlook, Dev Home, Feedback Hub, Get Help, Microsoft 365 hub, Power Automate, To Do, Films & TV, old Mail, Family, Phone Link, Widgets and sponsored stubs (Disney+, LinkedIn). Spotify is not removed (people install it on purpose; its Start advertising is gone with the clean Start pins). Windows is told not to install "suggested" apps silently, and its to-do entries that would bring Dev Home and Outlook back are removed. Kept since 2.3.0: Tips, Cortana, Maps and Mobile devices (Cross Device, needed to use a phone with the PC).

- **OneDrive** (option, on): removed with its own uninstaller. Your files stay.
- **Maximum** (option, off): also the Xbox app, Photos, Camera, Sound Recorder, Clock, Sticky Notes. The Store stays.

### Privacy and advertising
- Diagnostic data level 0 (`AllowTelemetry` = 0); the telemetry service and its helper are disabled.
- Scheduled data collection is disabled, including the compatibility appraiser, known for long disk and CPU bursts, and its second job `MareBackup`.
- The policy "Turn off Application Telemetry" is set. The compatibility engine that old games rely on is not touched.
- All other documented diagnostic-data policies that work on Pro: no feedback prompts, no extra diagnostic logs or crash dumps collected, the diagnostic data choice in Settings is locked to the policy; CEIP, Steps Recorder, Windows Error Reporting and MRT infection reports off; no learning from typing and inking, no online speech recognition, no handwriting data sharing; Edge optional diagnostic data off (Edge then shows "managed by your organization", as with any policy).
- Advertising ID, tailored experiences, feedback prompts, activity history and Recall are off.
- Suggestions and advertising in Start, Settings, the lock screen and notifications are off (`ContentDeliveryManager`: content delivery, rotating lock screen and its tips, suggested content in Settings and Start).
- Windows Firewall stays on for the private and public networks; only its pop-up notifications are off.
- Cross Device Resume (continuing on the PC what you did on the phone) is off.
- Start menu search no longer sends what you type to Bing. The Widgets board is off.

### Services and background work
- **Basic set (option, on):** scheduled jobs of removed apps and of data collection (offline map updates, family safety, disk check proxy, SQM). Edge stays, but no longer keeps processes running after its window is closed. Services themselves are left as Windows sets them: printing, Bluetooth, fax, diagnostics, sync and the small system drivers are not touched.
- **Your choice (options, off):** file indexing, hibernation with Fast Startup, background activity of Store apps. Each of these removes a function, so each is a separate tick.
- **Telemetry services and jobs (always applied):** error reporting (WerSvc), compatibility assistant (PcaSvc), telemetry (DiagTrack), Windows AI components host (WSAIFabricSvc), the inventory collector (InventorySvc); the Distributed Link Tracking Client (TrkWks) stays as Windows has it, Automatic (versions 1.6.7–2.1.0 deleted it; on such PCs its saved registration is put back and the service started again); plus 14 scheduled telemetry jobs: device census, usage-data reporting, sustainability telemetry, startup-app scan, troubleshooting scans, disk and power diagnostics, WinSAT, error-report upload. Defragmentation/TRIM, registry backup, restore points, SysMain, time sync and Defender stay. Versions 1.5.0–1.6.0 switched off more (diagnostics, sync, small drivers, printing, Bluetooth, the basic services, the restart policy); installing 1.6.0 or later puts all of those back to what they were before the first install.
- **Hypervisor launch type:** versions 1.5.7–1.6.0 switched the hypervisor start off when virtualization was off in the BIOS. That step is gone (if virtualization is switched on later, memory integrity and VBS would silently not start); installing 1.6.2 or later puts the previous value back.
- What this gives: fewer processes and less memory in use after start-up — you can see it in Task Manager. It does not raise FPS by itself.
- Never switched off: Defender, Windows Update, audio, network, input, Task Scheduler, WMI, the Xbox services, TPM and Secure Boot services, anti-cheat services.

### Windows Update (two options, on by default)
- **No preview builds (always):** the policies `AllowBuildPreview` = 0 and `EnableExperimentation` = 0 in `HKLM\SOFTWARE\Policies\Microsoft\Windows\PreviewBuilds`: no Insider builds and no feature experiments.
- **Hold Windows on 26H2 (no further feature updates)**: `TargetReleaseVersion` = 26H2. On 26H2 nothing changes but the pin; on 25H2 this means one feature update to 26H2 (a small enablement update with one restart), then no further feature updates. **26H2 gets security updates until October 2028:** before then, apply a newer Domain OS version (it moves the pin) or run "Give Windows Update back its defaults" from the Start menu folder "Domain OS".
- **No drivers from Windows Update:** you install the makers' drivers; the driver guide shows which.

Security updates keep coming. The Start menu folder "Domain OS" has a shortcut that puts everything back.

### Gaming settings
- **Game capture off:** background recording (Game DVR) and recording by hand, plus the policy that forbids recording and broadcasting. Windows 11 ships with background recording off; if it was switched on, it cost GPU and disk time in every game — now it stays off until you allow recording again.
- **Pointer acceleration off.**
- **Sticky / Filter / Toggle Keys shortcuts off**, so five presses of Shift no longer throw a window over the game.
- **Game Bar off (since 1.6.8).** It does not open on Win+G or the controller's Xbox button, but the app stays installed and can be switched on in Settings > Gaming. Undo puts the previous values back.
- **Xbox mode off (since 1.6.8):** the full-screen Xbox experience (Settings > Gaming > Xbox mode) is not used as the home screen. The Xbox app itself stays. Undo puts the previous value back.
- **Game Mode stays on**, as Windows ships it: AMD's 3D V-Cache driver on Ryzen X3D with two CCDs uses it to keep games on the V-Cache CCD, and it keeps Windows Update from installing drivers or asking to restart during a game.
- **Hardware-accelerated GPU scheduling (HAGS), always on (since 2.3.0 no longer an option):** `HwSchMode` = 2 in `HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers`. The graphics card schedules its own work, which takes some CPU work and latency off frame submission. Needs a supported GPU and driver (NVIDIA GTX 10 and newer, AMD RX 5000 and newer, Intel Arc); otherwise Windows ignores it. Works after a restart; Undo puts the previous value back.
- **`Win32PrioritySeparation` = 0x18:** long, fixed time slices, the same length for the program in front and for background programs (Windows' own value gives short, variable slices with three times the slice in front). Why 0x18: measurements by Zero Unflesh found 0x18 **together with Game Mode on** to be the best combination, and that is exactly what Domain OS ships (Game Mode stays on). Our own A/B test on 19.11.2026 (one PC, CS2 on an empty map, the same spot, variants alternated) found no measurable difference between 0x18 and Windows' 0x26: FPS, 1% / 0.1% low and frame times were within the run-to-run spread. So 0x18 stays on the strength of those measurements; runs from other PCs are welcome on the results page. Undo restores the previous value.

### Interface
File extensions are shown and Explorer opens on "This PC". No effect on performance is claimed.

- **Clean taskbar** (option, on): every pinned program is unpinned and the search, Task view and Chat buttons are hidden, so only the Start button stays (plus programs while they run). The original pins are saved and Undo puts them back. Only the first install clears the taskbar: when a newer version is applied over an older one, the programs you pinned since stay pinned. Without this option search becomes an icon.
- **Start menu pins** (with "remove preinstalled apps"): the pinned list is rebuilt from installed programs — Settings, File Explorer, Edge, Domain OS Toolbox, and the Store, Xbox, Terminal and Notepad when present — so the tiles of removed apps (Copilot, Teams, Outlook, Solitaire, the "Other" folder) disappear. It uses the `ConfigureStartPins` policy with `applyOnce` (Windows 11 24H2 with KB5062660 and later): Start replaces its pinned list at the next sign-in and never again, so pins can be changed as usual. On older builds a one-time task removes the policy after it was applied. First install only; Undo puts the original Start pins back.

- **Dark theme** (option, on): for Windows and for apps.
- **Notifications off** (option, off by default since 2.1.1): the main switch in Settings → System → Notifications. No pop-ups or sounds over a game. Defender keeps working; its state is visible in Windows Security. Switch notifications back on in Settings at any time.
- **Administrator rights without the UAC prompt** (option, off by default since 2.1.9): your account was already an administrator; now a program that asks for administrator rights gets them without the "Do you want to allow this app to make changes?" window. UAC itself stays on, so Store apps, Xbox and anti-cheats keep working. The price: any program you start that asks for rights gets them silently, so run only what you trust. It is off by default: tick it only if you want the convenience; Undo brings the prompt back. Without the tick (since 2.3.0) UAC asks for the account's password or PIN at every elevation (`ConsentPromptBehaviorAdmin` = 3), not only a Yes / No.

### Power plan (option, on)
**Domain OS** — a fresh copy of Windows' Balanced plan with four plugged-in settings changed and nothing else. Processor settings, core parking and boost stay exactly as in Balanced, which is what AMD and Intel tune their processors for; on battery a laptop behaves as with Balanced.

| Setting | Value | What it does |
|---|---|---|
| USB selective suspend | off | USB hubs, mouse, keyboard, headset and USB audio never go to sleep. |
| PCI Express link state power management (ASPM) | off | Graphics card, NVMe and network card stay fully awake on their PCIe link. |
| Turn off display after | never | A convenience (no dark screen in long loading screens or while watching), not a performance setting. On an OLED monitor you may want a timeout: Settings → System → Power. |
| Turn off hard disk after | never | |

The plan that was active before is remembered; Undo makes it active again and deletes this one. Installing 1.6.0 over an older version rebuilds the plan from Balanced, so the processor values of the old "Domain OS Low Latency" plan are gone.

### Tools
- **DomainScheduler** (option, on): installed to `Program Files\Domain OS` and started with Windows for every user. It places a game's threads and lowers background programs while you play.
- **Runtimes** (option, on): Visual C++ 2015–2022 x64 and x86, the DirectX June 2010 runtime, 7-Zip — downloaded from the vendors; Microsoft files are accepted only with a valid Microsoft signature, and 7-Zip (which has no signature) only as one known version whose SHA-256 matches the value in `Install-Runtimes.ps1`.
- **Driver guide** (option, on): after the restart a page opens (with your account's normal rights, not as administrator) that was built for your PC: which drivers to install, in which order, with links to the official pages, and how to install an NVIDIA driver without extras using NVCleanstall. It also checks the monitor's refresh rate and whether the memory runs at its rated speed.
- **Wallpapers** (option, on): the Domain OS pictures are copied to `C:\Windows\Web\Wallpaper\Domain OS`. The desktop gets a slideshow of them (a new picture every 10 minutes, shuffled) and the lock screen gets one of them. A theme "Domain OS" appears in Settings → Personalization → Themes to choose the slideshow again later. Windows has no supported way for a program to turn on a lock screen slideshow, so to get one: Settings → Personalization → Lock screen → Slideshow → Browse → `C:\Windows\Web\Wallpaper\Domain OS`. These are ordinary settings, nothing is locked; Undo puts back the earlier desktop and lock screen pictures. A copy of your earlier picture is kept in `%ProgramData%\Domain OS\Undo\Wallpaper\<account>`, which only that account and administrators can read. Installed over 1.4.0–2.1.0 (which set a Domain OS picture themselves), the original is taken from the state those versions saved before their first change; if it is gone, Undo sets the Windows default picture.
- **Shortcut:** "Domain OS Toolbox" on the desktop and in the Start menu.
- **Check Domain OS** (always): Start menu → Domain OS → Check Domain OS. See [Checking](#checking).

## Undo

Domain OS changes settings; it does not cut components out of Windows. That is why it can be taken back.

- **Before the first change** the playbook writes down the current state of every registry value, service and scheduled task it may touch (`%ProgramData%\Domain OS\Undo\state.json`, plus a second copy of the original, `state.original.json`, that is written once and never changed). If the state cannot be saved, or a saved state is damaged, the install **stops before any change** and leaves the file as it is.
- **Undo Domain OS is installed next**, still before any change, so it is in the Start menu even if the install stops part-way.
- **Start menu → Domain OS → Undo Domain OS** puts that state back: registry, service start-up types, scheduled tasks, hibernation, OneDrive, the power plan, taskbar and Start pins, wallpapers, and deletes the record of the chosen options (`HKLM\SOFTWARE\Domain OS\Options`). Then restart. If something could not be put back, the log says what, the saved state is kept, and you run Undo again after the restart. Services and scheduled tasks that Windows does not let administrators change (they belong to TrustedInstaller or SYSTEM) are put back by a one-shot step that runs as SYSTEM and is removed right after.
- **Removed apps** are not restored automatically: the script lists them, reinstalls the Microsoft Store if it was removed, and you install the ones you want from the Store.
- Run it with `-WhatIf` to see what would be done (also when it asks for administrator rights first), and with `-RemoveTools` to remove the Domain OS app as well (the app's own full reset runs first, then the playbook's values are put back).
- **The saved state is protected:** `%ProgramData%\Domain OS` can be changed only by administrators (inheritance off; SYSTEM and Administrators full control, Users read only). Undo and the installer use a saved file only if SYSTEM, Administrators, TrustedInstaller or an administrator account owns it (a standard account cannot plant one; files that older versions saved under your administrator account are given to the Administrators group), restore only registry values, services and tasks that the playbook's task files can touch, and read saved `.reg` exports value by value instead of importing them.

**Per-user settings and several accounts.** AME Wizard writes the playbook's per-user (HKCU) settings into **every account on the PC and into the default profile for accounts created later**. The saved state and Undo cover **the account that runs Undo** only: other accounts keep the Domain OS per-user settings (pointer acceleration, dark theme, taskbar buttons, suggestions and the rest); change them in Settings there. Taskbar pins, Start pins and wallpapers are changed for the installing account only, and Undo puts them back when that account runs it.

**What Undo does not put back:**
- OneDrive for accounts created later (the default profile's first-sign-in entry stays removed; OneDrive can be installed from microsoft.com or the Store);
- Windows Update's to-do entries for Dev Home and the new Outlook (`Orchestrator\UScheduler_Oobe`; Windows writes them again with the next feature update);
- the installed runtimes (Visual C++, DirectX, 7-Zip) — they stay; uninstall them in Settings → Apps if you want;
- the Domain OS pictures in `C:\Windows\Web\Wallpaper\Domain OS` and the per-user settings of other accounts (see above).

## Stopping on errors

The install **stops at the first error** in its own steps: every step that runs one of the Domain OS scripts stops AME Wizard when the script ends with an error, and the reason is written to `%ProgramData%\Domain OS\Logs\install.log` (a line with `FAILED`). The scripts end without an error when they did their work or had nothing to do. One exception: the runtimes (Visual C++, DirectX, 7-Zip) are downloaded from the vendors, so a server or connection problem only goes to `runtimes.log`; install them again any time from Start → Domain OS → Install runtimes.

Windows' own actions (registry values, services, scheduled tasks, apps) cannot simply stop on an error, because a service or task that this Windows build does not have would stop every install. Instead, the **last step checks everything**: `Check-DomainOS.ps1 -AfterInstall` compares the PC with the list of every change (`expected.json`, generated from the task files when the playbook is built) for the options you chose. A service, task or app that this build does not have is skipped; any value or state that differs stops the install with an error. Each difference is one line in `%ProgramData%\Domain OS\Logs\check.log`: what, what was expected, what was found, and the task file and line that sets it.

The state for Undo is saved before the first change, so a stopped install can always be undone with Undo Domain OS.

The options you chose are recorded in `HKLM\SOFTWARE\Domain OS\Options` (one value per option). It is Domain OS' own record, not a Windows setting: it is not part of the saved state, and Undo deletes it after a complete undo.

## Checking

**Start → Domain OS → Check Domain OS** checks the PC at any time. It only reads: it never changes a setting, a service, a task, an app or a file (the only thing it writes is its report). It asks for administrator rights and shows PASS / WARN / FAIL on screen, then saves the full report on the desktop (`Domain OS check <date>.txt`) — send that file when you ask for help.

What it checks:
- **every change of the playbook** for the options recorded at the install, as at the end of the install (on another account, the per-user settings of the account that runs the check);
- **Undo is ready**: the data folder's protection (owner, permissions, no links), the saved state (`state.json`, `state.original.json`), Undo's tools and its allow-list (it must cover every change), and a **dry run of Undo** (`-WhatIf`) that must finish without a failure;
- the Domain OS scheduled tasks (normal rights, no window), the Toolbox autostart and its version, the version applied last, `FAILED` lines of the last install, errors of Domain OS programs in the event logs;
- **Windows health**: `DISM /CheckHealth` and `sfc /verifyonly` (read-only; together they can take several minutes; `-Quick` leaves them out), devices with a driver problem, a pending restart, Windows Update (service, last successful search and install), disk health, unexpected shutdowns and blue screens of the last 7 days, the most frequent errors in the event logs of the last 24 hours, free space on the system drive. Each WARN or FAIL comes with advice in plain words.

A FAIL in the Domain OS part means something is not as Domain OS set it: usually another program or a Windows update changed it, or you changed it yourself in Settings. Applying the playbook again puts it right; Undo still returns the original state.

### Trying a version, going back, installing a newer one
1. Apply a version. Its number and date go to `%ProgramData%\Domain OS\history.log`.
2. If you do not like it: **Undo Domain OS**, restart. Windows is as it was before; the saved state is used up (if Undo reported a failure, it is kept: run Undo again).
3. Apply the newer version like the first time: it saves a fresh state before its first change.

You can also apply a newer version **over** an older one without undoing: the original state is kept, and whatever the newer version touches in addition is added to it, so one Undo still returns everything.

## Considered and left out

| Change | Why it is not here |
|---|---|
| Timer resolution, `bcdedit` tick options | Since Windows 10 2004 the timer request is per process; no reproducible gain. |
| MMCSS / `SystemResponsiveness` / `NetworkThrottlingIndex` | Affect only multimedia-class threads; no reproducible gain in games. |
| Disabling Search | Breaks file search; the saved memory is not measurable in frame times. (SysMain always stays on.) |
| Processor idle states off (`IDLEDISABLE`), performance thresholds and check intervals | Idle states off raises temperature and takes boost headroom away; the thresholds are ignored by processors with hardware P-state control (Intel HWP, AMD CPPC). |
| Disabling ~40 ETW sessions and ~120 scheduled tasks | The tasks run in the maintenance window while the PC is idle; they do not run during a game. Only the sessions of the service we disable ourselves are switched off. |
| Disabling `Ndu`, `DPS` | There is a mechanism (`Ndu` sits on the network path) but no measurement. It will be added when a WPA trace shows numbers. |
| `SvcHostSplitThresholdInKB` | Saves 100–200 MB of memory, frees no CPU time, and services lose isolation from each other. |
| Dozens of undocumented values under `Control\Power` and `Session Manager\kernel` | No evidence that current builds read them at all. |
| Disabling fullscreen optimizations | No reproducible gain; the optimizations are what gives flip mode and VRR. |
| Disabling mitigations, VBS, Defender | Measurable on some systems, but it trades away security and anti-cheat support. Not offered. |

If you can show a measured, repeatable improvement for something on this list, open an issue with the numbers.

## Earlier versions: what they did and how it was put back

Domain OS has not always been as careful as it is now. Everything below was removed, and machines that had it get the previous values back by themselves.

| Versions | What it did | Now |
|---|---|---|
| Toolbox 1.6–1.11 | Optional "test mode" switches that traded protection for speed: memory integrity / VBS / hypervisor off, Spectre and Meltdown workarounds off, exploit-protection defaults off, Defender and SmartScreen policies off. Off by default, switched on only by hand. | Removed in **1.12.0**. Every start and the factory reset put back the values saved before any of them was switched on. |
| Toolbox test builds (before 1.12.0) | Could add the running game's exe to Defender's exclusions while it ran. | Removed. Toolbox only takes off exclusions such a build left behind (at every start and exit); it never adds any. |
| Playbook up to 1.5.8 | Switched off diagnostic services, sync and background services and small system drivers; printing and Bluetooth could be switched off with optional ticks. | Removed in **1.5.9**; installing a newer version puts the previous values back from the saved state. |
| Playbook 1.5.7–1.6.0 | Turned the hypervisor start off when virtualization was off in the BIOS. | Removed; the step now restores the hypervisor start (see above). |
| Playbook 1.6.7–2.1.0 | Removed the Distributed Link Tracking Client (TrkWks). | 2.1.1 restores it and sets it back to automatic. |
| Playbook up to 2.1.1 (before the evening of 18.11.2026) | Removed the Microsoft Store Spotify together with the advertising stubs and blocked its return. | Spotify is no longer removed; the block is lifted on install. |
| Playbook up to 2.1.1 | `%ProgramData%\Domain OS`, where the state for Undo is saved, had no permissions of its own; a failed state save did not stop the install; Undo was installed last; the driver guide opened with administrator rights. | The folder gets its own permissions (administrators only can change it) and an existing one is repaired; saved files are used only when an administrator account or Windows wrote them; a failed save stops the install before any change; Undo is installed right after the save; the guide opens with normal rights. |

Since 2.0 the rule is: Defender, SmartScreen, VBS / memory integrity, TPM and Secure Boot are not touched, by the playbook or by Toolbox.

## How to use
1. Install a clean Windows 11 Pro, 25H2 or 26H2. **Before the first connection to the internet** run `extras/No-WU-Drivers.reg`: otherwise Windows Update installs its own drivers before the playbook can forbid it. Then finish Windows Update and restart.
2. Download AME Wizard and `Domain-OS-2.3.0.apbx`. Since 2.3.0 AME Wizard asks you to switch off the four main toggles in Windows Security (real-time protection and the others) before it starts: Domain OS does not change Defender, the wizard only needs it quiet while it works. **Switch them back on after the restart** (Windows Security > Virus & threat protection > Manage settings).
3. Drag the `.apbx` into AME Wizard, choose the options, start.
4. Restart. The driver guide opens: follow it from top to bottom.

AME Wizard will say that the playbook is not verified: verification is issued by the AME team and this project does not have it yet.

## Build from source
`./build.sh` (needs `7zr` and Python 3 with PyYAML): checks the task files and every PowerShell script, writes `playbook/Executables/expected.json` with `tools/gen-expected.py` (the list of every change, with file and line, that Check Domain OS compares the PC with; the build also stops when `Tasks/options.yml` does not record exactly the options of `playbook.conf`), then packs `playbook/` into a 7z archive with the password `malte`, as AME Wizard expects.

**Toolbox** is in this repository too: `toolbox/` holds its full source (C#, .NET 8, WPF) with the tests. The source follows development, so it can be newer than the released Toolbox; the released program is `DomainOS-Toolbox-1.15.0.exe` in [Releases](https://github.com/6kane1/DomainOS/releases).
- `./build.sh` — packs the exe saved as `toolbox/DomainScheduler.exe` (the released one; the build goes on without the app if it is missing);
- `./build.sh path/to/DomainScheduler.exe` — packs that exe;
- `./build.sh --toolbox-from-source` — builds Toolbox from `toolbox/src` first (needs the .NET 8 SDK);
- tests: `dotnet test toolbox/tests/DomainScheduler.Tests`.

**Proof that a Toolbox exe is built from this source:** from 1.15.0 on, Toolbox is built on GitHub's own machines by `.github/workflows/toolbox-build.yml` (tests first), and every exe gets a signed build-provenance attestation. Check any copy with the GitHub CLI: `gh attestation verify DomainScheduler.exe -R 6kane1/DomainOS` — it names the workflow and the exact commit; a file changed by even one byte fails. (1.14.1 and the test builds before 1.15.0 were built before this existed.)

**Proof that the playbook archive is built from this source:** from 2.2.4 on, `Domain-OS-<version>.apbx` is built by `.github/workflows/apbx-build.yml` on GitHub's machines: it takes the attested Toolbox exe (and checks its attestation), runs the whole test suite, packs and attests the archive. Check it with `gh attestation verify Domain-OS-2.2.4.apbx -R 6kane1/DomainOS`. The archive is encrypted with a random salt, so a rebuild never has the same SHA-256: the attestation binds the published file.

Downloads are checked with SHA-256: `Get-FileHash .\Domain-OS-2.3.0.apbx` in PowerShell must match the value on the website and in the release notes.

## Team

- **6kane1** — author and owner of Domain OS.
- **Zero Unflesh (zero_wake)** — co-owner of Domain OS and owner of AerialOS. Made a very large contribution to this project.

## License
**Domain OS License** — all rights reserved (see [LICENSE](LICENSE)). You may read the code and use the official releases free of charge on your own PCs. Copying, re-uploading, publishing changed versions or builds based on this code, removing the author notices and selling are not allowed without the author's written permission. Versions published before 18 November 2026 under MIT stay MIT for the copies obtained then.
Windows is a trademark of Microsoft; this project ships no part of Windows.
