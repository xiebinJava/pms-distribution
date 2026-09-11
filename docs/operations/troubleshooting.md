# 故障排查

先检查服务状态：

```bash
./scripts/status.sh
./scripts/logs.sh backend
./scripts/logs.sh mysql
```

常见问题：

- MySQL 未就绪：启动脚本会先检查 Docker 内存分配，默认至少需要 2 GiB；查看 `mysql` 日志；
- 迁移失败：保留数据库卷，查看 `backend` 日志里的 Flyway 输出，不要重复删除和创建数据库；
- 登录失败：确认管理员密码、浏览器时间、前端入口和后端就绪状态；
- 页面打开但 API 失败：确认前端容器健康，并检查 Nginx `/api` 代理日志；
- 升级后数据异常：停止继续写入，保留日志和备份，按升级说明回滚或恢复。
- 备份被拒绝：确认 `mysql` 显示为 healthy，且 `${COMPOSE_PROJECT_NAME:-<仓库目录名>}_pms-uploads` 卷存在；脚本不会在不完整栈上生成可误用的备份；
- 恢复被拒绝：必须使用 `RESTORE_CONFIRM=YES`，同时提供归档和同名 `.sha256` 文件。归档成员、校验和、元数据、目标数据库和目标卷都必须通过检查；恢复仅支持隔离的非生产配置；
- 升级未就绪：保留脚本输出的诊断，查看 `./scripts/logs.sh mysql backend frontend`。升级会恢复 `.env` 中的旧版本，但已执行的数据库迁移需要按发布说明和备份处理。

提交公开 Issue 前，请删除密码、令牌、数据库连接串和业务数据，并附上系统版本、Docker 版本、Compose 输出和请求时间。
