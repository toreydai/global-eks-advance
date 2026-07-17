# Global EKS Advance Workshop
## AWS EKS Advanced Hands-on Lab Collection

基于 EKS 1.35 · Amazon Linux 2023 · 全球区（us-east-1）· Prompt 驱动执行

> 本 workshop 是 [`global-eks-quickstart`](../global-eks-quickstart/README.md) 的进阶补充。建议完成 QuickStart 基础档后再执行本 workshop。

---

## Lab 列表

### 1. 平台与多集群治理

- [Lab01 — EKS Auto Mode 深度演示](docs/lab01-eks-auto-mode.md)
- [Lab02 — 多集群管理（Argo CD Hub-Spoke）](docs/lab02-multi-cluster-argocd.md)
- [Lab11 — Kyverno 策略治理](docs/lab11-kyverno.md)

### 2. 成本、流量入口与交付

- [Lab03 — Kubecost 成本优化](docs/lab03-kubecost.md)
- [Lab07 — Gateway API 和 AWS Load Balancer Controller 入口进阶](docs/lab07-gateway-api-lbc.md)
- [Lab08 — CodePipeline 进行 EKS CI/CD](docs/lab08-codepipeline-cicd.md)

### 3. AI、数据与日志平台

- [Lab04 — AI Agent on EKS](docs/lab04-ai-agent-on-eks.md)
- [Lab05 — GenAI 推理服务（GPU + vLLM）](docs/lab05-genai-gpu-vllm.md)
- [Lab06 — Spark on EKS](docs/lab06-spark-on-eks.md)
- [Lab09 — OpenSearch 和 Fluent Bit 日志平台](docs/lab09-opensearch-fluentbit.md)

### 4. 运维维护

- [Lab10 — EKS 集群升级与维护](docs/lab10-cluster-upgrade.md)
- [Lab12 — Istio 服务网格](docs/lab12-istio.md)

---

## 与中国区版本（china-eks-advance）的关系

中国区对应版本见 [`china-eks-advance`](https://github.com/toreydai/china-eks-advance)，覆盖同一批 Lab，按中国区约束做了适配（`arn:aws-cn:` ARN、`.amazonaws.com.cn` ECR 域名、镜像统一转存私有 ECR、安全组禁止 `0.0.0.0/0` 等），且中国区 Bedrock 不可用故无 Lab04。

---

## 使用方式

1. 在此目录下打开 Claude Code，`CLAUDE.md` 自动加载全球区 EKS Advance 配置
2. 将对应 [`docs/`](docs/) 目录中的 Lab 文件内容粘贴到对话框，由 AI 自主执行
3. 每个 Lab 末尾均有清理要求；涉及 GPU、OpenSearch、多集群、EMR、Kubecost 的 Lab 应优先清理以避免持续计费

与中国区版本（`china-eks-advance/`）的差异：

| 项目 | 全球区 | 中国区 |
|------|--------|--------|
| IAM ARN | `arn:aws:` | `arn:aws-cn:` |
| ECR 域名 | `.amazonaws.com` | `.amazonaws.com.cn` |
| 工具 / Helm Chart | 直接从 GitHub / Helm Hub 下载 | 从 S3 工具桶预置包 |
| 镜像仓库 | docker.io / quay.io / registry.k8s.io 均可访问 | 受限，需私有 ECR |
| Bedrock | us-east-1 可用 | 中国区不可用 |
| OIDC issuer | `oidc.eks.${AWS_REGION}.amazonaws.com` | `oidc.eks.${AWS_REGION}.amazonaws.com.cn` |

---

## 环境要求

| 工具 | 版本 |
|------|------|
| AWS CLI | 2.x |
| eksctl | latest（Auto Mode 需支持 EKS Auto Mode） |
| kubectl | v1.35 |
| Helm | 3.x |
| jq | latest |
| Docker | 24.x+ |
| git | latest |

操作机建议使用 Amazon Linux 2023 EC2，绑定具备 EKS、EC2、IAM、ECR、S3、CloudFormation、CodeBuild、CodePipeline、CodeCommit、OpenSearch、Bedrock、EMR Containers、DynamoDB、Secrets Manager 操作权限的 IAM Role。

---

## 特别说明

| Lab | 额外要求 |
|-----|----------|
| Lab02 多集群管理 | 需要至少 2 个 EKS 集群，建议提前预创建 Spoke 集群 |
| Lab04 AI Agent | Bedrock 模型需在 `us-east-1` 开通 |
| Lab05 GenAI 推理 | 需要 GPU 实例配额（g5 / g6） |
| Lab06 Spark on EKS | 需要 S3 bucket；EMR on EKS 相关权限 |
| Lab09 OpenSearch | OpenSearch 域创建约 15-20 分钟且持续计费 |
| Lab12 Istio | 建议在临时集群或独立 namespace 中执行 |

---

## License

MIT - see the [LICENSE](LICENSE) file for details.

## 免责声明

本项目仅供学习与技术参考，不构成生产部署方案。运行过程中会创建 AWS 资源并产生费用，请在实验结束后及时清理。作者不对因使用本项目产生的任何费用或损失承担责任。本项目与 Amazon Web Services 无官方关联，相关服务的可用性与定价以 AWS 官方文档为准。生产环境使用前请根据实际需求进行安全评估与调整。
