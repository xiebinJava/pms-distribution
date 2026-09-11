# 干净环境冒烟验收

在发布或升级一个发行版本前，用一台没有 Java、Node.js、Maven、pnpm 和本地数据库的机器完成下面的检查。记录命令输出，不要把密码、JWT 或连接串贴进公开 Issue。

## 前置条件

- Docker Desktop 或 Docker Engine + Compose v2
- Docker 至少分配 2 GiB 内存
- 可以匿名拉取 `PMS_VERSION` 对应的 backend / frontend GHCR 镜像
- 主机入口端口（默认 `5173`）空闲

## 检查清单

| # | 步骤 | 期望 | 结果 |
| --- | --- | --- | --- |
| 1 | `bash scripts/verify-ghcr-images.sh` | backend / frontend 镜像匿名可读 | 发布前必过 |
| 2 | `./scripts/bootstrap.sh` | 生成 `.env` 和 `.pms-bootstrap-secrets`（MySQL/JWT），服务健康 | 发布前必过 |
| 3 | 打开 `http://localhost:5173`，用 `admin@example.com` / `PmsAdmin123!` 登录 | 登录页可用，管理员可进入工作台 | 发布前必过 |
| 4 | `docker compose --env-file .env -f compose.yaml restart` 后再次登录 | 项目和附件数据仍在 | 发布前必过 |
| 5 | `./scripts/backup.sh` | 生成含数据库和附件的归档 | 发布前必过 |
| 6 | 在新 Compose 项目名上 `RESTORE_CONFIRM=YES ./scripts/restore.sh <归档>` | 恢复后数据可读 | 发布前必过 |
| 7 | `./scripts/upgrade.sh <下一版本>`（有下一版本时） | 备份成功，迁移完成，`/api/health/ready` 通过 | 有跨版本时必过 |
| 8 | 启动失败时查看 `./scripts/logs.sh mysql` 或 `./scripts/logs.sh backend` | 能定位到 Docker、配置、数据库或迁移层 | 发布前抽查 |

## 推荐命令

```bash
bash scripts/test-distribution-contract.sh
bash scripts/test-compose-config.sh
bash scripts/test-operations-safety.sh
./scripts/check-privacy.sh
bash scripts/verify-ghcr-images.sh
./scripts/bootstrap.sh
./scripts/status.sh
```

停止服务但保留数据：

```bash
docker compose --env-file .env -f compose.yaml down
```

不要使用 `down -v`，除非这次验收明确要销毁卷。

## 1.0.2 记录

| 项目 | 状态 |
| --- | --- |
| 匿名 GHCR 拉取 | 已通过：`pms-backend` / `pms-front` `1.0.2` |
| 干净机器三步启动 | 已通过：隔离项目 `pms-smoke`，入口 `http://localhost:15173`，管理员可登录 |
| 重启保留数据 | 已通过：`compose restart` 后同一管理员仍可登录，`sys_user` 仍为 1 行 |
| 备份恢复 | 已通过：归档含 database/uploads，恢复到隔离库后 `sys_user` 仍为 1 行 |
| 已知限制 | 发行路径为 MySQL 8.4；更换数据库栈前先停掉旧 Compose 项目 |
