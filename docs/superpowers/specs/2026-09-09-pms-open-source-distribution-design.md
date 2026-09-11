# PMS 开源统一发行包设计

## 目标

为 PMS 建立一个独立的统一发行入口，让没有 Java、Node.js、Maven、pnpm 或数据库经验的用户，可以通过 Docker Compose 使用固定版本的前后端镜像完成安装、初始化、升级、备份和恢复；现有 `pms-backend` 与 `pms-front` 保留为源码仓库，不删除、不迁移历史。

## 现状与约束

- 后端和前端目前是两个独立 GitHub 仓库：`pms-backend`、`pms-front`。
- 后端当前正式运行路径为 MySQL 8，已有 Flyway 迁移、健康检查和生产配置校验。
- 前端通过 Nginx 提供静态资源，并代理 `/api` 到后端。
- 两个源码仓库已有 Apache-2.0、README、贡献指南、安全策略和 CI。
- 发行仓库不得保存数据库密码、JWT Secret、SMTP 密码、对象存储密钥或真实业务数据。
- 第一阶段不改变项目业务模型，不引入微服务，不重写现有前后端架构。

## 仓库职责

### 源码仓库

`pms-backend` 和 `pms-front` 负责：

- 源码、单元测试、类型检查和集成测试；
- Dockerfile 和镜像构建工作流；
- 后端源码仓库构建 `pms-backend` 镜像；Flyway 在后端启动时执行迁移；
- 对应版本的变更记录；
- 面向开发者的本地开发文档。

### 发行仓库

新增 `pms-distribution` 负责：

- 面向用户的快速开始文档；
- 固定版本的 Compose 文件；
- `.env.example` 与配置说明；
- 安装、升级、备份、恢复和故障排查脚本；
- 支持矩阵、版本说明和发布记录；
- 不包含前后端源码副本，避免三份代码漂移。

## 发行架构

默认用户路径使用预构建镜像：

```text
浏览器
  ↓
pms-frontend 镜像（Nginx，单一入口）
  ↓ /api
pms-backend 镜像（Spring Boot）
  ↓
MySQL 8
```

发行 Compose 必须满足：

- 默认只暴露前端入口端口；
- 后端和数据库端口默认只在容器网络内可见；
- 服务使用固定版本标签，不使用 `latest`；
- 数据库由 `mysql:8.4` 初始化，迁移由后端 Flyway 执行，不挂载源码仓库路径；
- 数据库和附件使用命名卷；
- 后端、前端和数据库都有健康检查或明确的就绪依赖；
- 后端使用非 root 用户运行；
- 启动失败时日志能指出配置、数据库连接或迁移原因。

## 配置合同

发行仓库提供 `.env.example`，至少包含：

- `PMS_VERSION`：发行版本；
- `PMS_FRONTEND_IMAGE`、`PMS_BACKEND_IMAGE`：镜像地址；
- `PMS_PORT`：前端入口端口；
- `MYSQL_ROOT_PASSWORD` 或外部数据库连接配置；
- `MYSQL_USER`、`MYSQL_PASSWORD`；
- `PMS_JWT_SECRET`；
- `PMS_BOOTSTRAP_ADMIN_EMAIL`、`PMS_BOOTSTRAP_ADMIN_PASSWORD`；
- `PMS_DEPLOYMENT_ENV`；
- 可选的 SMTP、对象存储、CORS 和上传配额配置。

所有敏感配置只通过本地 `.env`、Docker secrets 或外部密钥系统注入；示例文件只提供占位说明，不提供可登录的默认密码。

## 用户操作合同

快速体验路径：

```bash
git clone https://github.com/xiebinJava/pms-distribution.git
cd pms-distribution
cp .env.example .env
./scripts/bootstrap.sh
```

脚本负责校验 Docker/Compose、检查端口、生成缺失的随机密钥、检查必要配置、拉取固定版本镜像、启动服务、等待健康检查并输出访问地址。

日常运维路径：

```bash
./scripts/status.sh
./scripts/logs.sh
./scripts/backup.sh
./scripts/restore.sh <backup-file>
./scripts/upgrade.sh <version>
```

`restore.sh` 必须要求用户显式确认，不能覆盖当前数据而不提示；`upgrade.sh` 在升级前必须执行备份，并记录当前版本与迁移结果。

## 数据库策略

运行时只支持 MySQL 8。`compose.yaml` 使用 `mysql:8.4`，后端启动时由 Flyway 执行迁移。

## 安全与供应链

- 公开发布前执行 Secret 扫描、依赖漏洞扫描和容器镜像扫描；
- 发布镜像提供 SBOM 或依赖清单；
- 发布工作流只在 Git Tag 或受保护分支执行；
- 不在日志、审计和错误响应中输出密码、令牌或数据库连接串；
- 生产模式关闭 token 回显，启用 HTTPS、受限 CORS 和正式 SMTP 校验；
- 发布前检查截图、演示数据和 fixtures 中不存在真实个人信息。

## 可维护性

- 发行仓库的版本与后端数据库迁移版本保持可追踪关系；
- 每个版本提供变更记录、升级说明和已知限制；
- 源码仓库发布镜像后，发行仓库再更新版本引用；
- GitHub Issues 至少提供安装问题、Bug 和功能建议模板；
- README 首屏只保留项目价值、三步启动、默认访问地址和文档入口。

## 验收标准

在一台没有 Java、Node.js、Maven、pnpm 和数据库的干净机器上：

1. 只安装 Docker Desktop 或 Docker Engine + Compose Plugin；
2. 按 README 的三步命令启动；
3. 在合理时间内打开登录页并完成管理员初始化；
4. 重启容器后项目和附件数据仍然存在；
5. 执行备份并恢复到新卷后数据可读；
6. 从一个发行版本升级到下一个版本，迁移成功且服务健康；
7. 不需要修改源码，不需要手动执行数据库 SQL；
8. 失败时能从文档定位到 Docker、配置、数据库或迁移层。
