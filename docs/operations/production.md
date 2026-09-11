# 生产配置

快速启动默认是本地评估配置，不代表生产安全基线。生产部署前至少完成以下配置：

- 设置 `PMS_DEPLOYMENT_ENV=production`；
- 使用密钥管理器注入数据库密码和 `PMS_JWT_SECRET`；
- **更换**初始管理员密码（禁止继续使用公开默认值 `PmsAdmin123!`）；
- 关闭 `PMS_PASSWORD_RESET_EXPOSE_TOKEN` 与 `PMS_INVITATION_EXPOSE_TOKEN`；
- 通过 HTTPS 反向代理暴露前端入口；
- 将 `PMS_CORS_ALLOWED_ORIGINS` 限制为正式域名；
- 配置 SMTP、对象存储、备份和监控告警；
- 不把后端、数据库或管理端口直接暴露到公网。

Docker Compose 只负责单机服务编排。高可用、外部数据库、集中日志和密钥托管应由部署环境提供。

