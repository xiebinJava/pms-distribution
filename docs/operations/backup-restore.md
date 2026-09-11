# 备份与恢复

备份同时覆盖 `pms` 数据库和 `pms-uploads` 命名卷。备份文件不包含 `.env` 或密钥；生产环境应把生成的归档发送到受控、加密的备份存储。

```bash
./scripts/backup.sh
RESTORE_CONFIRM=YES ./scripts/restore.sh backups/<timestamp>.tar.gz
```

默认输出目录为 `backups/`，每次备份生成时间戳归档和同名 `.sha256` 校验文件。归档内含 `metadata.env`、压缩数据库导出、上传文件归档及其成员校验和。导出使用 `mysql:8.4` 中的 `mysqldump`，并且只有 MySQL 健康时才会开始。

恢复必须提供 `RESTORE_CONFIRM=YES`，先验证外层和成员校验和、归档成员与元数据，以及内层 uploads 归档的可读性和安全路径，之后才检查 Docker 前置条件。它绝不覆盖运行中的 `pms` 或当前“仓库目录名（或 `COMPOSE_PROJECT_NAME`）`_pms-uploads`”卷；默认创建新的数据库和新的上传卷，并打印其名称。可用 `RESTORE_DATABASE` 和 `RESTORE_UPLOADS_VOLUME` 指定隔离目标，但目标已存在、数据库为 `pms` 或卷为当前上传卷时仍会拒绝。

在 Linux 上脚本使用 `sha256sum`，在 macOS 上使用 `shasum -a 256`。数据库客户端密码仅通过权限为 600 的临时 Docker env-file 注入，命令行不会展开密码；临时目录会在退出时清理。

脚本拒绝生产配置（`PMS_DEPLOYMENT_ENV=production`）。请先在独立的非生产 Compose 项目和维护窗口执行恢复演练；恢复完成后，按输出的数据库和卷名称连接只读验证数据与附件，确认无误后再安排正式迁移。
