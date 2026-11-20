# Threat model · Модель угроз

What Domain OS protects, against whom, how, and what is left. Kept next to [ARCHITECTURE.md](ARCHITECTURE.md);
update both with every change to a security-relevant part.

## Assets
1. **The user's Windows**: it must keep working and must always come back with Undo.
2. **Administrator rights**: the playbook runs as TrustedInstaller/administrator, Toolbox as administrator, Undo has a
   one-shot SYSTEM step. Nothing a standard user controls may steer them.
3. **The update channel**: only files the author published may be installed.
4. **Keys**: the update-signing main key (author's PC), the backup key (offline), the tester key (closed channel).
5. **The user's game account**: no anti-cheat must see Toolbox touch a protected game.
6. **Hardware**: GPU overclocking must not damage the card or leave the PC unbootable.

## Adversaries and what stops them

| # | Who / what | Attack | Mitigation | Tests |
|---|---|---|---|---|
| T1 | A program running as the **standard user** on the same PC | plants or changes Undo's state, a `.reg` export, Toolbox settings/backups, a link (junction/symlink) to steer an admin restore | data in `%ProgramData%\Domain OS` and `…\Domain OS Toolbox` with owner + ACL checked and repaired (`StateDir.Judge`, `Test-DomainOSFile`); files of a foreign owner or links are refused; Undo restores only allow-listed items (allow-list in Program Files); `.reg` import refuses anything outside its key, deletions, `..`, unknown types; restored values checked against what the program itself writes | `SecurityTests`, Pester `Common`/`Undo`, fuzz: `FuzzTests.FolderAnyoneElseCanWriteIsNeverTrusted`, `GpuProfileFileOfAnyContent…`, Pester `Import-DomainOSRegFile fuzz` |
| T2 | **Network attacker** / a changed mirror | serves a fake feed or a changed exe | feeds signed (ECDSA P-256), signature checked before parsing; every download checked by size + SHA-256 from the signed feed; HTTPS only; feed size capped | `UpdaterTests`, fuzz `FeedParserAcceptsOnlyValidFiles` |
| T3 | **Stolen main signing key** | signs a malicious feed | backup key offline; key-rotation procedure (`toolbox/README.md` → *Update keys and key rotation*): a feed signed with the backup key ships a Toolbox that drops the main key | rotation tests in `UpdaterTests` |
| T4 | **Leaked tester key** | reads test builds | only confidentiality of unfinished builds is lost; test builds are still signed feeds + SHA-256; new key = new seal | `SealedFilesOpenOnlyUntouched…` |
| T5 | **Compromised GitHub account / workflow** | pushes malicious code or a malicious release | `main` protected (PR + green tests, no force-push, also admins); actions pinned by SHA; release files attested (Sigstore) so a file not built by the workflow fails `gh attestation verify` | `tests.yml` area L (workflows pinned) |
| T6 | **Malformed driver data** (NVAPI/ADL tables, CfgMgr, CPU-set buffers) | crashes or out-of-range writes | parsers bounds-checked, values clamped to driver-reported ranges and program caps | fuzz `NvidiaClockTable…`, `AmdAdapterTable…`, `InterruptAndCpuSet…` |
| T7 | **Anti-cheat** | bans a user because Toolbox opened a protected game | `Guard`: games under a kernel anti-cheat and anti-cheat processes are never opened (not even for reading); measuring uses only kernel ETW | `SpecTests` (denylist) |
| T8 | **Unstable overclock** | crash loop at every boot | crash guard: a profile is not re-applied after an unexpected shutdown; values that crashed are remembered and marking them again asks first (1.16.0); AMD voltage only lowered; offsets capped | `Release1130Tests`, `Release1160Tests` |
| T9 | **Our own bug** | an install or Undo half done | install stops on any error; state saved before the first change; Undo keeps the state on any failure and can be run again; a real apply → undo round trip in CI on every change | `tests.yml` round trip, Pester |

## Not protected / residual risks (honest list)
- **An attacker who already has administrator rights** can do anything Domain OS can; out of scope.
- **A stolen main key until users update**: a client that has not yet received the rotation still trusts the main
  key. There is no threshold signing or offline root (TUF-style roles) yet.
- **The anti-cheat list is a blocklist**: an unknown game under a kernel anti-cheat is recognised by its loaded
  modules / running clients only; a new anti-cheat could be missed. No anti-cheat vendor has confirmed compatibility.
- **One maintainer + an AI co-author**, no external professional audit, no second human reviewer yet.
- **Tested on one real PC**; AMD overclocking has not met a real Radeon card.
- The `.apbx` is not byte-reproducible (7-Zip salt); the attestation binds the exact published file instead.

## Where to look first in a review
`playbook/Executables/DomainOS-Common.ps1` (file trust, allow-list, `.reg` import), `Undo-DomainOS.ps1`,
`Undo-AsSystem.ps1`, `toolbox/src/DomainScheduler.Lib/{Updater,StateDir,Guard,GpuProfiles,NvOc,AmdOc}.cs`,
`.github/workflows/*`.

---
Русский кратко: защищаем Windows пользователя, права администратора, канал обновлений, ключи, игровой аккаунт и
железо. Главные угрозы: программа обычного пользователя подкладывает файлы (папки с проверкой владельца и прав, откат
только по разрешённому списку), подмена обновлений (подписанные фиды + SHA-256), кража ключа (запасной ключ офлайн и
ротация), взлом GitHub (защита `main`, аттестации), античит (игры под античитом не открываются), нестабильный разгон
(защита от сбоев и память сбоев). Честно не закрыто: уже имеющий права администратора злоумышленник, окно до
обновления клиентов после кражи ключа, список античитов как чёрный список, один мейнтейнер без внешнего аудита.
