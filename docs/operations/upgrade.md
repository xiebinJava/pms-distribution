# 升级

升级前必须备份数据库和附件，并确认目标版本的发布说明没有数据迁移限制。

```bash
./scripts/backup.sh
./scripts/upgrade.sh 1.0.1
./scripts/status.sh
```

版本必须是语义版本号，例如 `1.0.1` 或 `1.1.0-rc.1`。脚本会先备份，随后以原子替换更新 `.env` 的 `PMS_VERSION`，拉取固定版本镜像并强制重建服务。它等待 backend 与 frontend 的容器健康状态，并通过 backend 内部的 `/api/health/ready` 验证就绪。

若拉取、迁移或健康检查失败，脚本会恢复原 `.env` 版本、用原版本重建 backend / frontend，并等待两个容器健康以及 `/api/health/ready`。回滚重建或就绪验证失败会明确输出失败原因，并保留 mysql、backend 和 frontend 的最近日志。数据库迁移本身不能自动逆转：不要删除容器或卷；保留备份和日志，运行 `./scripts/status.sh`，再按该版本发布说明决定恢复或人工处置。

所有脚本都支持相同的 Compose 合约，用于隔离测试或非默认文件：

```bash
COMPOSE_PROJECT_NAME=pms-staging ENV_FILE=.env.staging COMPOSE_FILE=compose.yaml ./scripts/upgrade.sh 1.0.1
```
