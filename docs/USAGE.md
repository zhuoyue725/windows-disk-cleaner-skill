# 使用教程

这份教程说明如何安装、扫描、清理、关闭软件后继续清理，以及什么时候使用深度清理或迁移。

## 1. 安装

进入项目目录后运行：

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1 -Target all
```

只装到某一个 agent：

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1 -Target codex
powershell -ExecutionPolicy Bypass -File .\install.ps1 -Target claude
powershell -ExecutionPolicy Bypass -File .\install.ps1 -Target workbuddy
```

安装脚本会把 `skills/windows-disk-cleaner` 复制到对应工具的本地 skills 目录。

推荐同时安装扫描引擎 gdu（报告功能的依赖）：

```powershell
powershell -ExecutionPolicy Bypass -File .\setup-gdu.ps1
```

## 2. 生成分析报告（推荐第一步）

无论是否要清理，先跑一份只读报告看看空间去哪了：

```text
用 windows-disk-cleaner 给我做一份全盘磁盘分析报告
```

或直接跑脚本：

```powershell
.\skills\windows-disk-cleaner\scripts\report.ps1
```

报告输出到 `%LOCALAPPDATA%\WindowsDiskCleaner\reports\`，包含 Markdown 和深色单文件 HTML 两个版本：磁盘告警环形图、各盘空间分布堆叠条、目录排行与大文件条形图（每项都标注完整路径）、按风险分档的清理建议，以及可直接复制的执行命令。`report.ps1` 全程只读，不删除任何文件。详见 [REPORT.md](REPORT.md)。

## 3. 推荐 agent 对话流程

日常清理：

```text
使用 windows-disk-cleaner 帮我清理 C 盘空间。
```

agent 应该执行：

1. 快速扫描 C 盘。
2. 保存清理计划。
3. 清理 `SAFE_DELETE` 项目。
4. 跳过正在运行的软件缓存。
5. 告诉用户关闭哪些软件后还能释放多少空间。

关闭软件后继续：

```text
我已经关闭 Chrome、WPS 和 aTrust 了，继续清理。
```

agent 应该复用上一次 `plan_path`，运行：

```powershell
.\skills\windows-disk-cleaner\scripts\clean_space.ps1 -PlanPath "<plan_path>" -Only SAFE_IF_CLOSED
```

不要重新完整扫描，除非计划文件不存在或用户明确要求重新扫描。

## 4. 直接脚本流程

快速扫描：

```powershell
.\skills\windows-disk-cleaner\scripts\scan_space.ps1 -Drives C: -Mode Fast
```

常见输出：

```text
Cleanup summary

risk           items size_mb size_gb
----           ----- ------- -------
SAFE_IF_CLOSED     7  797.09   0.778
SAFE_DELETE        1  108.49   0.106

Plan saved: C:\Users\you\AppData\Local\WindowsDiskCleaner\plans\windows-disk-cleaner-plan-20260619-001236.json
```

立即清理：

```powershell
.\skills\windows-disk-cleaner\scripts\clean_space.ps1 -PlanPath "<plan_path>"
```

预演：

```powershell
.\skills\windows-disk-cleaner\scripts\clean_space.ps1 -PlanPath "<plan_path>" -DryRun
```

关闭软件后继续：

```powershell
.\skills\windows-disk-cleaner\scripts\clean_space.ps1 -PlanPath "<plan_path>" -Only SAFE_IF_CLOSED
```

## 5. 风险分级

| 风险 | 含义 | 默认处理 |
| --- | --- | --- |
| SAFE_DELETE | 可自动删除的临时文件或缓存 | 可清理 |
| SAFE_IF_CLOSED | 软件关闭后可清理的缓存/日志 | 软件运行时跳过 |
| ADMIN_SAFE | 需要管理员权限或官方 Windows 清理工具 | 提示，不强行清理 |
| CONFIRM_REQUIRED | 下载、备份、归档、大文件等 | 逐项确认 |
| MIGRATE_ONLY | 游戏库、WSL/Docker、聊天文件根目录等 | 建议迁移，不删除 |
| NEVER_DELETE | 系统组件、驱动、聊天数据库、个人文件等 | 永不自动删除 |

## 6. 什么时候使用 Deep Scan

`Fast` 模式只看高确定性的缓存和日志，速度快，适合日常清理。

使用 `Deep` 模式的情况：

- C 盘空间很低，但快速扫描释放很少。
- 用户想知道大目录或大文件在哪里。
- 需要制定迁移策略，比如把 Docker、WSL、游戏库或大型应用数据迁移到 D 盘。

命令：

```powershell
.\skills\windows-disk-cleaner\scripts\scan_space.ps1 -Drives C: -Mode Deep
```

## 7. 管理员深度清理

深度清理应优先使用 Windows 官方工具：

```powershell
Dism.exe /Online /Cleanup-Image /AnalyzeComponentStore
Dism.exe /Online /Cleanup-Image /StartComponentCleanup
```

不要手动删除：

- `C:\Windows\WinSxS`
- `C:\Windows\Installer`
- `C:\Windows\System32`
- DriverStore
- Windows Update 数据库

## 8. 定时清理

创建每天 09:00 的低风险清理任务：

```powershell
.\skills\windows-disk-cleaner\scripts\schedule_cleanup.ps1 -Frequency Daily -At 09:00 -Level L1 -Drives C:
```

C 盘低于 20 GB 时升级到 L2：

```powershell
.\skills\windows-disk-cleaner\scripts\schedule_cleanup.ps1 -Frequency Daily -At 09:00 -Level L1 -EscalateToL2BelowGB 20
```

不要自动化迁移、备份删除、聊天数据删除或深度系统清理。

## 9. 维护建议

- 新增应用清理规则时，优先加入明确的缓存/日志目录。
- 不要把数据库、账号状态、聊天记录目录加入自动删除列表。
- 对需要关闭软件的目录，务必配置 `process_names`。
- 对需要管理员权限的目录，标记为 `ADMIN_SAFE`，不要在普通权限下强删。
