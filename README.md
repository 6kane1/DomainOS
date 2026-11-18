# Domain OS

**English** | [Русский](README.ru.md)

A playbook for [AME Wizard](https://ameliorated.io) that prepares **Windows 11 25H2 and 26H2 (builds 26200, 26300), Pro only**, for games. On Home and other editions the install stops at the first step, before any change.

> **25H2 and 26H2 since 2.1.0.** 24H2 is no longer supported: its security updates have ended. "No feature updates" holds the system on 26H2 (supported until October 2028).

**A short list of changes, each one explained and checkable.** Every value below names the registry key, service or setting it changes.

> **Before you start**
> - **It can be undone without reinstalling Windows** (see [Undo](#undo)). Removed apps are installed again from the Store. Still, try it in a virtual machine first.
> - **Average FPS does not go up** because of a playbook. What you get is fewer background processes, no advertising, no forced restarts and a system that is set up the same way every time.
> - Version 2.1.1 is new and has had little testing. Report what breaks.

## What stays untouched — on purpose

| Component | Why it stays |
|---|---|
| Microsoft Defender, SmartScreen, Windows Security | Removing them leaves the PC unprotected and breaks anti-cheats. |
| Secure Boot, TPM, VBS, memory integrity, kernel mitigations | FACEIT, Vanguard, EasyAntiCheat and BattlEye check them. |
| Security and quality updates, Defender definitions | A system without them is unsafe within weeks. |
| Xbox Identity Provider, Gaming Services, the Game Bar app | Games sign in and save through them. The Game Bar overlay is off, but the app is not removed. |
| Microsoft Store, App Installer (winget), Edge, WebView2 | Launchers and many programs need them. The Store can be removed with the "Maximum" option. |
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
Removes apps that advertise or start in the background: Clipchamp, News, Weather, Bing search, Solitaire, Teams, Copilot app, new Outlook, Dev Home, Feedback Hub, Get Help, Tips, Microsoft 365 hub, Power Automate, To Do, Films & TV, Cortana, Maps, old Mail, Family, Phone Link, Mobile devices (Cross Device), Widgets, and sponsored stubs (Spotify, Disney+, LinkedIn). Windows is told not to bring Dev Home and Outlook back and not to install "suggested" apps silently.

- **OneDrive** (option, on): removed with its own uninstaller. Your files stay.
- **Maximum** (option, off): also the Store, Xbox app, Photos, Camera, Sound Recorder, Clock, Sticky Notes.

### Privacy and advertising
- Diagnostic data at the required level; the telemetry service and its helper are disabled.
- Scheduled data collection is disabled, including the compatibility appraiser, known for long disk and CPU bursts, and its second job `MareBackup`.
- The telemetry trace sessions (`Diagtrack-Listener`, `SQMLogger`) no longer start at boot: with the service disabled nobody read their events.
- The policies "Turn off Application Telemetry" and "Turn off Inventory Collector" are set. The compatibility engine that old games rely on is not touched.
- All other documented diagnostic-data policies that work on Pro: no feedback prompts, no device name in diagnostic data, no extra diagnostic logs or crash dumps collected, no OneSettings download, no change notification; CEIP, Steps Recorder, Windows Error Reporting and MRT infection reports off; no learning from typing and inking, no online speech recognition, no handwriting data sharing; Edge optional diagnostic data off (Edge then shows "managed by your organization", as with any policy).
- Advertising ID, tailored experiences, feedback prompts, activity history and Recall are off.
- Suggestions and advertising in Start, Settings, the lock screen and notifications are off.
- Start menu search no longer sends what you type to Bing. The Widgets board is off.

### Services and background work
- **Basic set (option, on):** eight scheduled jobs of removed apps and of data collection (maps, family safety, disk check proxy, SQM). Edge stays, but no longer keeps processes running after its window is closed. Services themselves are left as Windows sets them: printing, Bluetooth, maps, fax, diagnostics, sync and the small system drivers are not touched.
- **Your choice (options, off):** file indexing, hibernation with Fast Startup, background activity of Store apps. Each of these removes a function, so each is a separate tick.
- **Telemetry services and jobs (always applied):** error reporting (WerSvc), compatibility assistant (PcaSvc), telemetry (DiagTrack), Windows AI components host (WSAIFabricSvc), the inventory collector (InventorySvc); the Distributed Link Tracking Client (TrkWks) stays as Windows has it, Automatic (versions 1.6.7–2.1.0 deleted it; on such PCs its saved registration is put back and the service started again); plus 14 scheduled telemetry jobs: device census, usage-data reporting, sustainability telemetry, startup-app scan, troubleshooting scans, disk and power diagnostics, WinSAT, error-report upload. Defragmentation/TRIM, registry backup, restore points, SysMain, time sync and Defender stay. Versions 1.5.0–1.6.0 switched off more (diagnostics, sync, small drivers, printing, Bluetooth, the basic services, the restart policy); installing 1.6.0 puts all of those back to what they were before the first install.
- **Hypervisor launch type:** versions 1.5.7–1.6.0 switched the hypervisor start off when virtualization was off in the BIOS. That step is gone (if virtualization is switched on later, memory integrity and VBS would silently not start); installing 1.6.2 or later puts the previous value back.
- What this gives: fewer processes and less memory in use after start-up — you can see it in Task Manager. It does not raise FPS by itself.
- Never switched off: Defender, Windows Update, audio, network, input, Task Scheduler, WMI, the Xbox services, TPM and Secure Boot services, anti-cheat services.

### Windows Update (two options, on by default)
- **No feature updates**: holds the system on 26H2 (TargetReleaseVersion). On 25H2 that means one update to 26H2, then no further feature updates.
- **No drivers from Windows Update:** you install the makers' drivers; the driver guide shows which.

Security updates keep coming. The Start menu folder "Domain OS" has a shortcut that puts everything back.

### Gaming settings
- **Game capture fully off:** background recording (Game DVR), recording by hand, recorded sound, cursor and microphone, plus the policy that forbids recording and broadcasting. Background recording costs GPU and disk time in every game.
- **Pointer acceleration off.**
- **Sticky / Filter / Toggle Keys shortcuts off**, so five presses of Shift no longer throw a window over the game.
- **Game Bar off (since 1.6.8).** It does not open on Win+G or the controller's Xbox button, but the app stays installed and can be switched on in Settings > Gaming. Undo puts the previous values back.
- **Xbox mode off (since 1.6.8):** the full-screen Xbox experience (Settings > Gaming > Xbox mode) is not used as the home screen. The Xbox app itself stays. Undo puts the previous value back.
- **Game Mode stays on**, as Windows ships it: AMD's 3D V-Cache driver on Ryzen X3D with two CCDs uses it to keep games on the V-Cache CCD, and it keeps Windows Update from installing drivers or asking to restart during a game.
- **Hardware-accelerated GPU scheduling (HAGS), on by default (option):** `HwSchMode` = 2 in `HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers`. The graphics card schedules its own work, which takes some CPU work and latency off frame submission. Needs a supported GPU and driver (NVIDIA GTX 10 and newer, AMD RX 5000 and newer, Intel Arc); otherwise Windows ignores it. Works after a restart; Undo puts the previous value back.
- **`Win32PrioritySeparation` = 0x18:** long, fixed time slices, the same length for the program in front and for background programs (Windows' own value gives short, variable slices with three times the slice in front). The author's choice since 1.6.7; Undo restores the previous value.

### Interface
File extensions are shown and Explorer opens on "This PC". No effect on performance is claimed.

- **Clean taskbar** (option, on): every pinned program is unpinned and the search, Task view and Chat buttons are hidden, so only the Start button stays (plus programs while they run). The original pins are saved and Undo puts them back. Only the first install clears the taskbar: when a newer version is applied over an older one, the programs you pinned since stay pinned. Without this option search becomes an icon.
- **Start menu pins** (with "remove preinstalled apps"): the pinned list is rebuilt from installed programs — Settings, File Explorer, Edge, Domain OS Toolbox, and the Store, Xbox, Terminal and Notepad when present — so the tiles of removed apps (Copilot, Teams, Outlook, Solitaire, the "Other" folder) disappear. It uses the `ConfigureStartPins` policy with `applyOnce` (Windows 11 24H2 with KB5062660 and later): Start replaces its pinned list at the next sign-in and never again, so pins can be changed as usual. On older builds a one-time task removes the policy after it was applied. First install only; Undo puts the original Start pins back.

- **Dark theme** (option, on): for Windows and for apps.
- **Notifications off** (option, off by default since 2.1.1): the main switch in Settings → System → Notifications. No pop-ups or sounds over a game. Defender keeps working; its state is visible in Windows Security. Switch notifications back on in Settings at any time.
- **Administrator rights without the UAC prompt** (option, on): your account was already an administrator; now a program that asks for administrator rights gets them without the "Do you want to allow this app to make changes?" window. UAC itself stays on, so Store apps, Xbox and anti-cheats keep working. The price: any program you start that asks for rights gets them silently, so run only what you trust. Untick it to keep the prompt; Undo brings it back.

### Power plan (option, on)
**Domain OS** — a fresh copy of Windows' Balanced plan with four plugged-in settings changed and nothing else. Processor settings, core parking and boost stay exactly as in Balanced, which is what AMD and Intel tune their processors for; on battery a laptop behaves as with Balanced.

| Setting | Value | What it does |
|---|---|---|
| USB selective suspend | off | USB hubs, mouse, keyboard, headset and USB audio never go to sleep. |
| PCI Express link state power management (ASPM) | off | Graphics card, NVMe and network card stay fully awake on their PCIe link. |
| Turn off display after | never | |
| Turn off hard disk after | never | |

The plan that was active before is remembered; Undo makes it active again and deletes this one. Installing 1.6.0 over an older version rebuilds the plan from Balanced, so the processor values of the old "Domain OS Low Latency" plan are gone.

### Tools
- **DomainScheduler** (option, on): installed to `Program Files\Domain OS` and started with Windows for every user. It places a game's threads and lowers background programs while you play.
- **Runtimes** (option, on): Visual C++ 2015–2022 x64 and x86, the DirectX June 2010 runtime, 7-Zip — downloaded from the vendors; Microsoft files are accepted only with a valid Microsoft signature.
- **Driver guide** (option, on): after the restart a page opens that was built for your PC: which drivers to install, in which order, with links to the official pages, and how to install an NVIDIA driver without extras using NVCleanstall. It also checks the monitor's refresh rate and whether the memory runs at its rated speed.
- **Wallpapers** (option, on): the Domain OS pictures are copied to `C:\Windows\Web\Wallpaper\Domain OS`. The desktop gets a slideshow of them (a new picture every 10 minutes, shuffled) and the lock screen gets one of them. A theme "Domain OS" appears in Settings → Personalization → Themes to choose the slideshow again later. Windows has no supported way for a program to turn on a lock screen slideshow, so to get one: Settings → Personalization → Lock screen → Slideshow → Browse → `C:\Windows\Web\Wallpaper\Domain OS`. These are ordinary settings, nothing is locked; Undo puts back the earlier desktop and lock screen pictures.
- **Shortcut:** "Domain OS Toolbox" on the desktop and in the Start menu.

## Undo

Domain OS changes settings; it does not cut components out of Windows. That is why it can be taken back.

- **Before the first change** the playbook writes down the current state of every registry value, service and scheduled task it may touch (`%ProgramData%\Domain OS\Undo\state.json`).
- **Start menu → Domain OS → Undo Domain OS** puts exactly that state back: registry, service start-up types, scheduled tasks, hibernation, OneDrive. Then restart.
- **Removed apps** are not restored automatically: the script lists them, reinstalls the Microsoft Store if it was removed, and you install the ones you want from the Store.
- Run it with `-WhatIf` to see what would be done, and with `-RemoveTools` to remove the Domain OS app as well.
- Per-user settings are restored for the account that runs the script.

### Trying a version, going back, installing a newer one
1. Apply a version. Its number and date go to `%ProgramData%\Domain OS\history.log`.
2. If you do not like it: **Undo Domain OS**, restart. Windows is as it was before; the saved state is used up.
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

## How to use
1. Install a clean Windows 11 Pro, 25H2 or 26H2. **Before the first connection to the internet** run `extras/No-WU-Drivers.reg`: otherwise Windows Update installs its own drivers before the playbook can forbid it. Then finish Windows Update and restart.
2. Download AME Wizard and `Domain-OS-2.1.1.apbx`.
3. Drag the `.apbx` into AME Wizard, choose the options, start.
4. Restart. The driver guide opens: follow it from top to bottom.

AME Wizard will say that the playbook is not verified: verification is issued by the AME team and this project does not have it yet.

## Build from source
`./build.sh` (needs `7zr` and Python 3): checks the task files and packs `playbook/` into a 7z archive with the password `malte`, as AME Wizard expects. The Toolbox app is not in this repository: download `DomainOS-Toolbox-1.8.0.exe` from the [website](https://6kane1.github.io/DomainOS/scheduler.html) and save it as `toolbox/DomainScheduler.exe`, or pass its path: `./build.sh path/to/DomainScheduler.exe`. Without it the playbook is built without the app.

## License
MIT. Windows is a trademark of Microsoft; this project ships no part of Windows.
