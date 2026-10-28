# 安全设计与风险边界

本 Skill 的目标不是"尽可能多地删除文件"，而是在释放空间的同时保护软件可用性、账号状态、聊天记录和个人文件。本文档说明它的安全机制，方便你在安装前审计。

## 默认永不删除

- 文档、桌面、图片、视频、音乐、下载目录中的个人文件
- 聊天数据库与主消息存储（微信 / 企业微信 / QQ / 钉钉 / 飞书等）
- 手机备份、系统备份、系统还原点
- `C:\Windows\WinSxS`、`C:\Windows\Installer`、`DriverStore`、`System32`
- `Program Files` 下的软件主体、驱动、安全软件数据库
- `pagefile.sys`、`swapfile.sys`
- 当前 agent 运行时目录与会话数据（`.codex/sessions` 等）

## 默认不强制

- 关闭用户正在运行的软件（只在候选标记为"需先关闭"时提示，由你手动关）
- 接管文件所有权、改权限、绕过安全软件自保护
- 删除软件主体目录或卸载软件
- 进程终止（除非你逐项确认）

## 删除前的多重防线

1. **允许根白名单**：`clean_space.ps1` 只允许删除特定 temp 目录和已知缓存路径，白名单之外的路径一律跳过并记录
2. **NeverDelete 黑名单**：路径片段二次校验（WinSxS / Installer / WeChat Files / Packages 等）
3. **计划文件隔离**：清理只能基于 `scan_space.ps1` 生成的 JSON 计划，且计划文件本身也在保护列表中
4. **DryRun 预演**：`-DryRun` 列出全部将删除项，不落盘
5. **风险档位**：`SAFE_DELETE`（直接可删）/ `SAFE_IF_CLOSED`（先关应用）/ `ADMIN_SAFE` / `CONFIRM_REQUIRED`（必须逐项确认）/ `NEVER_DELETE`
6. **审计输出**：每次清理输出删除/跳过明细与前后磁盘剩余空间对比

## 可恢复优先

- **回收站默认保留**：清空回收站必须显式传 `-ClearRecycleBin`
- **迁移带回滚**：`migrate_app_data.ps1` 复制 → 校验体积 → 原目录改名 `.bak` → 建 junction；失败自动还原备份，成功后保留 `.bak` 并输出回滚命令
- **报告只读**：`report.ps1` 全程只读扫描，不产生任何删除

## 诚实声明

- 这是一个社区项目，未经大规模审计。第一次使用请只跑 `scan_space.ps1` / `report.ps1`（只读），并审阅 `clean_space.ps1 -DryRun` 的输出后再实际清理
- 清理为永久删除（`Remove-Item -Force`），不走回收站；这是设计取舍——回收站不释放磁盘空间。因此执行 L1 以上清理前，请务必确认 DryRun 清单
- 企业管控设备（域策略 / 安全软件自保护）下，Windows Temp 等系统目录的清理可能被拦截，脚本会跳过并记录，不会强推
