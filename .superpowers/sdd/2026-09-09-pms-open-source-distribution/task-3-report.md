# Task 3 完成报告：升级、备份和恢复运维流程

## 修改文件

- 新增 `scripts/backup.sh`：统一使用 `ENV_FILE`、`COMPOSE_FILE` 和 `COMPOSE_PROJECT_NAME`；仅在 OceanBase 健康且当前上传卷存在时备份。使用 `PMS_MIGRATOR_IMAGE:PMS_VERSION` 的 `mysqldump` 导出 `brad_pms` 表数据，并归档上传卷。生成包含 `metadata.env`、数据库导出、上传归档、成员校验和的时间戳归档及外层 `.sha256` 文件。
- 新增 `scripts/restore.sh`：在任何 Docker 操作前要求 `RESTORE_CONFIRM=YES`，校验外层/成员校验和、归档成员和元数据。默认创建带时间戳的新数据库和新上传卷，拒绝 `brad_pms`、当前上传卷、既有目标及生产配置。
- 新增 `scripts/upgrade.sh`：校验目标和当前版本的语义版本格式，先调用备份，再原子替换 `.env` 中的 `PMS_VERSION`，拉取/重建服务，等待 backend/frontend 健康以及 `/api/health/ready`。失败时恢复旧 `.env` 并输出相关服务诊断。
- 新增 `scripts/test-operations-safety.sh`：使用临时环境和假 Docker 命令运行真实脚本，覆盖恢复缺少确认、备份缺少运行栈、升级版本非法这三个安全拒绝路径。
- 更新 `docs/operations/backup-restore.md`、`docs/operations/upgrade.md`、`docs/operations/troubleshooting.md`：说明归档结构、隔离恢复、升级回退行为、共享 Compose 合约和故障处理。

## TDD 记录

先创建 `scripts/test-operations-safety.sh`，首次运行：

```bash
bash scripts/test-operations-safety.sh
```

预期红灯：由于 `scripts/restore.sh` 尚未存在，测试在调用该脚本时以 “No such file or directory” 失败。随后实现最小脚本并运行相同测试至绿灯。

实现审查中识别到 `mysqldump --databases brad_pms` 会在导入时携带原数据库创建/选择语句，与隔离恢复目标相冲突；最终导出改为仅指定 `brad_pms`，恢复通过客户端目标参数写入新数据库。

## 验证结果

以下命令均以退出码 0 结束：

```bash
bash scripts/test-operations-safety.sh
bash -n scripts/backup.sh scripts/restore.sh scripts/upgrade.sh scripts/test-operations-safety.sh
bash scripts/test-docker-resources.sh
bash scripts/test-distribution-contract.sh
git diff --check
```

关键输出：

```text
Operation safety checks passed
Docker resource checks passed
distribution contract passed
```

## 已知限制

- 未在本工作区运行真实 Docker 的端到端备份、恢复和升级演练；发布前应在干净的非生产 Compose 项目中完成一次完整演练，并验证 migrator 镜像内存在 `mysqldump` 与 `mysql` 客户端。
- 失败的隔离恢复不会删除已新建的恢复数据库或恢复卷，避免自动删除数据；操作者确认无用后可在维护流程中手动清理这些明确命名的目标。
- 升级失败会回退 `.env` 和尝试恢复应用容器版本，但已经执行的数据库迁移无法自动逆转，必须依据备份和对应版本发布说明处理。
- 恢复脚本有意拒绝 `PMS_DEPLOYMENT_ENV=production`，生产恢复应通过隔离的非生产克隆进行验证并执行经过批准的迁移流程。

## 审查修订

- 所有 Compose 脚本（bootstrap、status、logs、backup、restore、upgrade）现在都显式传递 `--project-name`。未设置时默认值是仓库目录名 `pms-distribution`，因此默认卷和网络一致；`COMPOSE_PROJECT_NAME=pms-staging` 会被所有脚本一致使用。
- SHA-256 校验优先使用 Linux 的 `sha256sum`，不可用时回退至 macOS 的 `shasum -a 256`。
- 数据库密码不再作为 Docker `-e` 参数展开。备份与恢复在权限为 600 的工作目录临时 env-file 中写入 `MYSQL_PWD`，并由退出清理陷阱删除。
- 恢复在创建数据库或卷前，验证内层 `uploads.tar.gz` 可以读取且成员路径不是绝对路径或包含上级目录穿越。
- 升级回滚会重建旧版本 backend/frontend，等待两个服务健康并验证 `/api/health/ready`；任一阶段失败都会输出 `rollback failed`。
- 安全测试新增假 Docker 断言，验证默认项目名和 `pms-staging` 覆盖都会显式传给 Compose。
- 修订 `upgrade.sh` 调用 `backup.sh` 的边界：调用点现在显式传递 `ENV_FILE`、`COMPOSE_FILE` 和 `COMPOSE_PROJECT_NAME`，避免子脚本退回默认项目名。安全测试以 `pms-staging` 执行真实升级到备份的子进程路径，并由假 Docker 记录 backup 的 Compose 调用来验证该项目名已传入。
- 安全测试补强为隔离假 Docker 集成路径：验证 backup 使用项目网络/卷、restore 创建隔离目标并拒绝当前目标，以及升级失败后的旧 backend readiness 回滚检查。
