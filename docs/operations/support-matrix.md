# 支持矩阵

| 组合 | 状态 | 说明 |
| --- | --- | --- |
| Docker Compose v2 + MySQL 8.4 | 当前发行路径 | 默认安装方式；发布前按 [干净环境冒烟验收](clean-machine-smoke-test.md) 执行 |
| Kubernetes / Helm | 未承诺 | 源码仓库有可选 Helm chart，发行包仍以 Compose 为准 |
| PostgreSQL | 不支持 | 当前没有 PostgreSQL 迁移和集成测试 |
| SaaS 多租户 | 不支持 | 当前产品定位是单企业自部署 |

版本支持政策会在每次发行说明中写明。提交功能或兼容性问题时，请同时提供本表中的组合和发行版本。
