---
name: windows-disk-cleaner
description: Diagnose, clean, and manage Windows disk space when users ask to free C drive or other drive space, clean Windows junk files, find large files, remove caches/logs/update leftovers, safely clean app data, schedule recurring cleanup, or migrate high-growth app data from C drive to another drive. Supports scan-only, conservative cleanup, standard cleanup, deep administrator cleanup, and long-term migration strategies with strict safety rules.
---

# Windows Disk Cleaner

Use this skill as a Windows disk-space governance workflow: inspect first, classify risk, present a concise plan, execute only the approved cleanup level, verify, and report.

## Modes

Map the user's request to one mode:

- **scan**: inspect drives and produce recommendations only.
- **clean**: run L1 or L2 cleanup.
- **deep-clean**: use administrator-safe Windows cleanup and protected-cache handling after confirmation.
- **migrate**: move high-growth app data to another drive with a rollback path.
- **schedule**: create recurring low-risk maintenance.

Default mapping:

- "see what is taking space" -> `scan`, L0.
- "clean my PC/C drive" -> `clean`, L1.
- "clean as much as possible but keep software working" -> `clean`, L2.
- "deep clean" or "C drive is critically low" -> `deep-clean`, L3, confirm first.
- "C drive keeps growing" or "move software data to D" -> `migrate`, L4, confirm each item.
- "daily/weekly automatic cleanup" -> `schedule`, L1 with threshold upgrade to L2.

## Cleanup Levels

- **L0 Scan only**: no deletion.
- **L1 Conservative**: user temp, Windows temp, browser/app caches, logs, error reports, crash dumps, recycle bin.
- **L2 Standard**: L1 plus old app versions, update/installer leftovers, meeting dynamic resources, package manager caches, Git object compaction.
- **L3 Deep**: L2 plus official Windows component/update cleanup and protected log/cache cleanup. Require administrator context and confirmation.
- **L4 Migration**: move high-growth app data to another drive and create a directory junction. Require per-item confirmation and rollback.

For details, read `references/cleanup-levels.md`.

## Required Workflow

1. **Preflight**
   - Check Windows host, current user, administrator status, target drives, free space, and running processes/services.
   - If the system is enterprise-managed or security software is self-protected, do not force-stop services or change permissions.

2. **Scan**
   - Run `scripts/scan_space.ps1` first unless the user explicitly provided a recent scan.
   - Default to fast scan on the pressure drive, usually `C:`. Fast scan checks known temp/cache/log targets and writes a reusable JSON cleanup plan.
   - Use `-Mode Deep` only when the user asks to find large space consumers, when fast scan finds little space, or when the drive is critically low.
   - Treat `plan_path` from scan output as the handoff artifact for cleanup and later resume.

3. **Report**
   - Run `scripts/report.ps1` to produce the user-facing analysis report. This is the default deliverable, not the raw script output.
   - It writes both a Markdown report and a single-file dark HTML report under
     `%LOCALAPPDATA%\WindowsDiskCleaner\reports\`, and prints the paths.
   - The report contains: disk overview with tension status, where the space went (grouped by
     content type), ranked cleanup recommendations by risk tier, large items that need a human
     decision, and copy-pasteable execution commands.
   - Use `-Drives C:,G:` to limit scope, `-NoHtml` for Markdown only, `-TopFiles N` to change how
     many large files are listed.

4. **Classify**
   - Classify each candidate as `SAFE_DELETE`, `SAFE_IF_CLOSED`, `ADMIN_SAFE`, `CONFIRM_REQUIRED`, `MIGRATE_ONLY`, or `NEVER_DELETE`.
   - Use `references/risk-policy.md` and `references/app-patterns.md`.

5. **Plan**
   - Show a short user-facing summary: expected freeable space by risk class and one recommended action.
   - Do not show long path lists by default. Show top 3 categories and provide "view details" if needed.

6. **Execute**
   - Use `scripts/clean_space.ps1 -PlanPath <plan_path>` for L1/L2 cleanup after scanning.
   - If apps are running, skip `SAFE_IF_CLOSED` items and report which apps to close plus the estimated space.
   - When the user closes apps and says to continue, rerun cleanup with the same plan path and `-Only SAFE_IF_CLOSED`; do not rescan unless the plan is stale or missing.
   - For L3, prefer official Windows tools. Never manually delete `WinSxS`, `Windows Installer`, drivers, or security databases.
   - For L4, use `scripts/migrate_app_data.ps1` only after closing the app and getting explicit confirmation.

7. **Verify**
   - Recheck free space.
   - Report deleted, skipped, protected, and needs-confirmation items.
   - Confirm services remain running when cleaning security software logs.

8. **Schedule**
   - Use `scripts/schedule_cleanup.ps1` for recurring cleanup.
   - Automated cleanup may run L1 daily/weekly and L2 only when a free-space threshold is crossed.
   - Never automate deletion of backups, chat data, user documents, photos/videos, or migration actions.

## Safety Rules

Always protect:

- User documents, desktop files, pictures, videos, music, and personal downloads unless the user confirms specific items.
- Chat databases and primary message stores.
- Phone backups, system backups, and restore points unless the user explicitly confirms.
- `C:\Windows\WinSxS`, `C:\Windows\Installer`, `Program Files` software bodies, drivers, security software databases, `pagefile.sys`, `swapfile.sys`, and current agent runtime/session data.

Never force:

- `git reset`, filesystem ownership changes, permission rewrites, driver/service deletion, or security software self-protection bypass.
- Process termination unless the user explicitly approves closing named applications.

Prefer:

- Official Windows cleanup commands for system components.
- Software-native cleanup settings for WeChat/Enterprise WeChat, cloud drives, security products, Docker, WSL, and games.
- Migration or archival over deletion for user-created files.

## User Prompts

Keep prompts short. Use:

```text
Found about 12.4 GB that may be cleaned.

Low risk: 5.8 GB
Needs confirmation: 4.1 GB
Do not auto-clean: 2.5 GB

Recommended: Standard cleanup. It should not affect logins, documents, or chat history.
```

Offer at most three choices: recommended action, safer action, details.

Read `references/user-prompts.md` when crafting user-facing confirmations.

## Scripts

- `scripts/report.ps1`: **primary deliverable** — full-disk analysis + cleanup recommendations, writes Markdown and a dark single-file HTML report.
- `scripts/scan_space.ps1`: read-only scan and JSON/text summary, writes the reusable cleanup plan.
- `scripts/clean_space.ps1`: L1/L2 cleanup with allowlists and audit output.
- `scripts/migrate_app_data.ps1`: copy, junction, verify, rollback-friendly migration.
- `scripts/schedule_cleanup.ps1`: create a Windows scheduled task for recurring cleanup.

Run scripts with PowerShell. Use `-WhatIf` or `-DryRun` where available before higher-risk cleanup.

All `.ps1` files must be saved as **UTF-8 with BOM**. Windows PowerShell 5.1 reads
BOM-less files as ANSI, which garbles Chinese literals and can break string parsing.

## Report Output

`report.ps1` writes to `%LOCALAPPDATA%\WindowsDiskCleaner\reports\`:

- `disk-report-<timestamp>.md` — Markdown, readable in any editor or terminal
- `disk-report-<timestamp>.html` — dark single-file HTML, zero dependencies, works offline

Report sections:

1. 结论速览 — which drives are in the danger zone, how much is safely reclaimable
2. 磁盘总览 — capacity, used, free, tension status per drive
3. 空间去哪了 — grouped by content type, top-level directories, second-level heavy hitters, largest files
4. 清理建议 — ranked by risk tier, with the reason each tier requires care
5. 需要你决策的大额项目 — large items that must not be deleted automatically
6. 执行步骤 — copy-pasteable DryRun → low-risk → close-apps sequence

## Local Fixes (zh-CN locale)

Upstream matched robocopy's English summary labels (`Bytes`/`Files`), which never match on
non-English Windows, so every directory measured 0 bytes and the scan returned **zero
candidates**. Fixed by reading robocopy's summary block positionally instead of by label.

Additional hardening applied in this copy:

- `Clear-RecycleBin` is now opt-in via `-ClearRecycleBin` (upstream cleared it unconditionally).
- Allowed deletion roots no longer include the whole `LOCALAPPDATA` / `APPDATA`; only specific
  temp and known cache directories are permitted.
- Deep scan no longer walks the entire user profile, and skips model/inference cache paths
  (huggingface/torch/transformers/comfyui) whose rebuild cost is high.
- `migrate_app_data.ps1` size verification now works on localized systems.
- Comma-separated `-Drives C:,G:` is split into a proper array (PowerShell otherwise treats it
  as a single string, so every drive lookup silently fails).
- `report.ps1` runs gdu through the .NET Process API: `Start-Process` crashes when the
  environment contains both `HTTPS_PROXY` and `https_proxy`, and async
  `BeginOutputReadLine` drops most output when the process exits.
