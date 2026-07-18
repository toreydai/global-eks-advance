# AWS EKS Istio 多集群复测

本仓库用于在 AWS EKS 上复测 Istio primary-remote 多集群模式。当前脚本会在 `us-east-1` 创建两个 EKS 集群，安装 Istio，并用 HelloWorld/Sleep 验证跨集群服务发现和流量转发。

## 版本

- EKS Kubernetes：`1.36`
- Istio：`1.30.3`
- eksctl：`0.229.0`
- Region：`us-east-1`

## 文档

- [架构文档](docs/architecture.md)
- [部署和测试手册](docs/deploy-and-test.md)

## 快速开始

```bash
scripts/00-install-tools.sh
scripts/01-create-clusters.sh
scripts/02-install-istio.sh
scripts/03-verify.sh
```

成功标准：从 `istio-primary` 和 `istio-remote` 的 Sleep Pod 请求 `helloworld.sample:5000/hello` 时，都能看到 `Hello version: v1` 和 `Hello version: v2` 混合返回。

## 清理

```bash
scripts/99-cleanup.sh
```

清理会删除 `istio-remote` 和 `istio-primary` 两个 EKS 集群及其关联资源。删除 EKS managed node group、NAT Gateway、ELB 和 VPC 依赖时可能需要数分钟。

## License

MIT - see the [LICENSE](LICENSE) file for details.

## 免责声明

本项目仅供学习、测试和参考架构演示用途。执行脚本会创建 AWS 资源并产生费用，请在实验完成后及时执行清理。作者不对因使用本项目产生的任何费用、资源残留、安全风险或业务损失承担责任。所有命令和配置仅作为示例参考，生产环境使用前请根据实际需求进行安全评估、权限收敛和变更审核。
