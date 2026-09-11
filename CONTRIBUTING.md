# 贡献指南

感谢你帮助改进 PMS 发行包。

## 提交 Pull Request 之前

- 先阅读仓库根目录的 README 和支持矩阵。
- 不要提交 `.env`、凭据、备份、含真实数据的截图，或生成出来的数据卷。
- 发行用的 Compose 必须钉死明确的镜像版本，不要使用 `latest`。
- 跑通仓库合同、Compose、运维安全、隐私和脚本语法检查：

```bash
bash scripts/test-distribution-contract.sh
bash scripts/test-compose-config.sh
bash scripts/test-operations-safety.sh
./scripts/check-privacy.sh
bash -n scripts/*.sh docker/*.sh
```

- 在 Pull Request 里说明对安装或运维的可见影响。

## Pull Request

请保持改动小而聚焦。写清楚：

- 为什么改
- 实际执行过的验证命令
- 升级或回滚时要注意什么

会影响后端或前端行为的改动，应先在对应源码仓库实现并测试，再通过固定版本镜像进入本仓库。
