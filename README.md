# windows-disk-cleaner-skill

让 AI 编码助手（WorkBuddy / Codex / Claude Code）安全地管理 Windows 磁盘空间：**一键生成可视化分析报告，按风险分级清理，绝不越权删除。**

> 这是一个社区改进版（fork），原版来自 [ScauYjj/windows-disk-cleaner-skill](https://github.com/ScauYjj/windows-disk-cleaner-skill)（MIT）。
> 本版本修复了原版在**中文 Windows 上完全无法工作**的致命 bug，并新增了可视化分析报告，详见 [相对原版的改进](#-相对原版的改进)。

---

## 它能做什么

| 能力 | 说明 |
|---|---|
| 📊 **可视化分析报告** | 一条命令扫描全部磁盘，生成深色单文件 HTML 报告：环形图看告警、堆叠条看空间分布、条形图看目录排行，每根条都标注完整路径 |
| 🧹 **分级清理** | L1 保守 / L2 标准 / L3 管理员深度 / L4 迁移，清理前列出清单，支持 DryRun 预演 |
| 🛡️ **风险分级** | 每个候选标记为 `SAFE_DELETE` / `SAFE_IF_CLOSED` / `ADMIN_SAFE` / `CONFIRM_REQUIRED` / `NEVER_DELETE`，只清该清的 |
| 📦 **应用数据迁移** | 把大体积应用数据迁到其他盘，原路径建目录联接（junction），支持回滚 |
| ⏰ **定时维护** | 可注册 Windows 计划任务做每周低风险清理 |

**报告长这样**（深色、单文件、零依赖、可离线打开）：

- 顶部每个磁盘一个环形图：已用比例、剩余空间、告警状态
- 每个磁盘一个分区：堆叠条显示空间被哪些目录吃掉，下面每根条形对应一个目录，**完整路径 + 体积 + 内容性质（AI 模型 / 项目 / 回收站 / 缓存…）**
- 报告中的目录均可点击，直接在 **Windows 资源管理器** 打开，不需要复制路径
- 清理建议按风险分档，每档附"怎么清"的具体操作
- 大额项目（模型权重、引擎资产、WSL 虚拟盘）单独列出，明确标注"不该删，建议迁移"

## 环境要求

| 组件 | 要求 |
|---|---|
| 操作系统 | Windows 10 (1809+) / Windows 11 |
| PowerShell | 5.1（系统自带）或 7+ |
| AI 编码助手 | WorkBuddy / Codex CLI / Claude Code 任一（支持 `SKILL.md` 目录格式） |
| [gdu](https://github.com/dundee/gdu)（可选但强烈推荐） | 分析报告的扫描引擎；不装也能用基础扫描清理，但报告会缺目录排行和大文件列表 |

## 快速开始

```powershell
# 1. 克隆
git clone https://github.com/zhuoyue725/windows-disk-cleaner-skill.git
cd windows-disk-cleaner-skill

# 2. 安装 skill 到本机所有支持的 agent
powershell -ExecutionPolicy Bypass -File .\install.ps1 -Target all

# 3. 安装 gdu 扫描引擎（自动尝试 winget → choco → scoop → 直接下载）
powershell -ExecutionPolicy Bypass -File .\setup-gdu.ps1
```

安装后重启终端（winget 安装的 gdu 需要重开才会进 PATH），然后直接对 AI 助手说：

```text
用 windows-disk-cleaner 给我做一份全盘磁盘分析报告
```

或者更保守：

```text
使用 windows-disk-cleaner 扫描 C 盘，只给我安全清理建议，先不要删除。
```

> 对 Chinese locale 系统零障碍：脚本输出、报告、风险说明全部中文，且已修复原版在非英文 Windows 上扫描结果恒为零的问题。

## 直接用脚本（不通过 AI）

所有脚本都可以独立运行：

```powershell
cd skills\windows-disk-cleaner\scripts

# 生成分析报告（Markdown + 深色 HTML），只读、不删任何文件
.\report.ps1

# 只扫 C 盘和 G 盘
.\report.ps1 -Drives C:,G:

# 扫描已知清理目标，生成可复用的清理计划
.\scan_space.ps1 -Drives C: -Mode Fast

# 预演：只列出会删什么，不真删
.\clean_space.ps1 -PlanPath "<上一步输出的 plan 路径>" -DryRun

# 实际清理（低风险项，无需关软件）
.\clean_space.ps1 -PlanPath "<plan 路径>" -Only SAFE_DELETE

# 关掉 Chrome/Edge/IDE 后，再清这一批
.\clean_space.ps1 -PlanPath "<plan 路径>" -Only SAFE_IF_CLOSED

# 迁移大目录到其他盘（原路径变 junction，可回滚）
.\migrate_app_data.ps1 -Source "C:\Users\你\AppData\Local\某个大目录" -DestinationRoot "D:\" -DryRun
```

报告和计划保存在 `%LOCALAPPDATA%\WindowsDiskCleaner\`（`reports\` 与 `plans\`）。

## 报告怎么读

| 区块 | 内容 |
|---|---|
| 磁盘卡片 | 每盘一个环形图：已用比例、剩余空间、告警状态（<5% 严重告警 / <10% 告警 / <20% 注意） |
| 可释放空间 | 按风险档位汇总：立即可清 / 关软件后可清 / 需管理员 |
| 各盘空间分布 | 堆叠条 = 前几个目录占已用空间的比例；每根条形下方标注完整路径与体积 |
| 清理建议 | 每档列出候选路径、体积、归属应用，并附"怎么清"（推荐走官方命令还是直接删） |
| 需要你决策 | 大额但不应删除的项目：AI 模型权重、引擎资产、WSL 虚拟盘、Git 仓库等，给出迁移/压缩建议 |

## 🔧 相对原版的改进

原版在中文（非英文）Windows 上**扫描结果恒为 0**，本版本修复并加固了以下问题：

| # | 问题 | 修复 |
|---|---|---|
| 1 | **locale bug（致命）**：用英文正则匹配 robocopy 的 `Bytes:` 汇总行，中文系统输出 `字节:` 永不匹配 → 所有目录体积为 0 → 候选全被过滤 | 改为按汇总块位置取值（目录/文件/字节三行结构固定），语言无关 |
| 2 | 每次清理**无条件清空回收站**，连带销毁用户待恢复文件 | 改为 `-ClearRecycleBin` 显式开关，默认保留 |
| 3 | 允许删除根包含整个 `LOCALAPPDATA`/`APPDATA`，越权风险高 | 收紧为具体 temp 目录 + 展开到 Profile 级的已知缓存路径 |
| 4 | Deep 扫描递归整个用户主目录，会命中模型/推理缓存 | 只扫 AppData 两区，排除 huggingface/torch/comfyui 等高重建成本路径 |
| 5 | `migrate_app_data.ps1` 体积校验同样受 locale bug 影响，迁移安全检查形同虚设 | 同步修复 |
| 6 | `-Drives C:,G:` 被 PowerShell 当成单个字符串，盘符查找静默失败 | 手动 split 成数组 |
| 7 | `Start-Process` 在 `HTTPS_PROXY`/`https_proxy` 并存时崩溃 | 改用 .NET Process API |
| 8 | 异步读取进程输出在退出时丢数据（1TB 盘只收到 2 行） | 同步 `ReadToEnd()`，先启动全部进程再依次读取以保留并行 |
| 9 | **新增**：`report.ps1` 可视化分析报告（环形图 + 堆叠条 + 条形图，深色单文件 HTML） | — |

所有脚本必须保存为 **UTF-8 with BOM**（PowerShell 5.1 对无 BOM 文件按 ANSI 解析，中文会损坏）。

## 安全设计

- **默认不碰**：文档/桌面/下载/图片/视频、聊天数据库、手机备份、`WinSxS`、`Windows Installer`、驱动、当前 agent 的会话数据
- **默认不强制**：关闭正在运行的软件、改文件所有权/权限、绕过安全软件
- **可恢复优先**：删除前列清单、支持 DryRun、保留回收站（需显式指定才清空）、迁移保留 `.bak` 备份与回滚命令
- 详见 [docs/SECURITY.md](docs/SECURITY.md)

## 常见问题

**Q: 报告里没有目录排行 / 提示 gdu 未安装？**
运行 `.\setup-gdu.ps1`。winget 装完需重开终端。

**Q: 扫描出来的候选是 0？**
如果你在自己改脚本，检查文件是否带 UTF-8 BOM、是否用了本仓库的修复版（原版有 locale bug）。

**Q: 支持哪些 agent？**
任何支持 `SKILL.md` 目录格式、能跑 PowerShell 的工具：WorkBuddy（`~/.workbuddy/skills`）、Codex CLI（`~/.codex/skills`）、Claude Code（`~/.claude/skills`）。

**Q: 会把文件传到云端吗？**
不会。全部本地执行、本地生成报告，无任何网络上传。

## License

MIT，延续原版协议。感谢原作者 [ScauYjj](https://github.com/ScauYjj/windows-disk-cleaner-skill)。
扫描引擎 [gdu](https://github.com/dundee/gdu)（MIT）由 [dundee](https://github.com/dundee) 开发，本仓库脚本会在用户同意下自动安装它。

## English (brief)

An agent skill that lets AI coding assistants (WorkBuddy / Codex / Claude Code) safely manage Windows disk space: generates a single-file dark-theme HTML analysis report with donut / stacked-bar / bar charts (every bar labeled with its full path), classifies cleanup candidates by risk tier with DryRun support, and migrates large app data directories to other drives via NTFS junctions with rollback.

This is a hardened fork of [ScauYjj/windows-disk-cleaner-skill](https://github.com/ScauYjj/windows-disk-cleaner-skill): the original silently measured every directory as 0 bytes on non-English Windows (it matched robocopy's English `Bytes:` label only). This version is locale-independent, no longer clears the Recycle Bin unconditionally, narrows deletion roots to specific cache paths, and adds the visual report. MIT licensed.
