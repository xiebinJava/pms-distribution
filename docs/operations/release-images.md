# 发布镜像

## 顺序

1. 先在 backend、frontend 仓库跑通测试。
2. 分别打同一版本的 `vX.Y.Z` 标签，或用 workflow dispatch 指定版本。
3. 确认 GHCR 上的版本标签和 `sha-<commit>` 多架构 manifests。
4. 更新发行仓库的 `PMS_VERSION`，完成干净 Compose 冒烟。
5. 发布 distribution Release。

工作流只在版本标签或手动触发时运行，使用 `GITHUB_TOKEN` 与 `packages: write` 推送。发行包现在只消费 `pms-backend` 与 `pms-front`；数据库使用 `mysql:8.4`，Flyway 随后端启动。

## 匿名校验

首次发布时用手动 dispatch 发一次，默认跳过匿名验证；随后确认 GitHub Packages 中 `pms-backend`、`pms-front` 为 Public。发行仓库用下面的脚本做匿名验证（必须接受 OCI index / manifest list，不能只请求单架构 schema v2）：

```bash
bash scripts/verify-ghcr-images.sh
```

`1.0.2` 的三次匿名检查已通过。后续版本标签推送会强制匿名验证。版本与 `sha-<commit>` 标签都是不可变标识：任一已存在即失败。

发行仓库打 `vX.Y.Z` 标签前，`.env.example` 的 `PMS_VERSION` 必须与标签一致。干净环境验收见 [干净环境冒烟验收](clean-machine-smoke-test.md)。
