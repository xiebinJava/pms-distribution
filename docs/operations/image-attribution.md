# 发行镜像归因

每个发行版本引用的第三方镜像仍受其各自许可证约束。`1.0.7` 的坐标如下。

| 镜像 | 用途 | 来源 |
| --- | --- | --- |
| `ghcr.io/xiebinjava/pms-front:1.0.7` | Nginx 前端入口 | `pms-front` 源码仓库 |
| `ghcr.io/xiebinjava/pms-backend:1.0.7` | Spring Boot API 与 Flyway 迁移 | `pms-backend` 源码仓库 |
| `mysql:8.4` | 默认数据库 | Oracle MySQL |
| `busybox:1.36.1-musl` | 附件目录初始化 | BusyBox |

发布镜像时，backend 与 frontend 的 GitHub Actions 会为应用镜像生成 SBOM（`sbom: true`）。升级 `PMS_VERSION` 时同步更新本表。
