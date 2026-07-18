# 部署和测试手册

## 重要免责声明

本手册仅供学习、测试和参考架构演示用途。执行脚本会创建 EKS、EC2、ELB、NAT Gateway、VPC、IAM、CloudFormation 等 AWS 资源并产生费用。请勿在生产账号中直接执行未经审核的命令。实验完成后请及时运行清理脚本，并确认相关资源已经删除。

## 前置条件

执行环境需要：

- 可用 AWS 凭据
- 足够权限创建和删除 EKS、EC2、IAM、CloudFormation、ELB、VPC
- 已安装 `aws`、`kubectl`、`curl`、`tar`、`jq`、`make`、`getent`
- `us-east-1` 中存在 EC2 key pair：`kp_virginia`

检查 AWS 身份：

```bash
aws sts get-caller-identity
```

预期输出包含 `Account` 和 `Arn`。

检查 key pair：

```bash
aws ec2 describe-key-pairs --region us-east-1 --key-names kp_virginia
```

预期输出包含：

```text
KeyName: kp_virginia
```

## 1. 安装工具

```bash
scripts/00-install-tools.sh
```

预期输出：

```text
0.229.0
Client Version: v1.35.0
client version: 1.30.3
```

工具会安装到 `.tools/`，不会覆盖系统版本。

## 2. 创建 EKS 集群

```bash
scripts/01-create-clusters.sh
```

会创建：

- `istio-primary`
- `istio-remote`

预期关键输出：

```text
EKS cluster "istio-primary" in "us-east-1" region is ready
EKS cluster "istio-remote" in "us-east-1" region is ready
```

最终节点状态应类似：

```text
NAME                 STATUS   VERSION
ip-...ec2.internal   Ready    v1.36.2-eks-...
ip-...ec2.internal   Ready    v1.36.2-eks-...
```

如果长时间看到：

```text
waiting for CloudFormation stack ...
```

通常是 EKS control plane、managed node group、NAT Gateway 或 VPC 依赖资源仍在创建。

## 3. 安装 Istio

```bash
scripts/02-install-istio.sh
```

该步骤会：

- 生成 CA 证书
- 安装 primary Istio control plane
- 安装两个 east-west gateway
- 创建 remote secret
- 应用 EKS FQDN 兼容处理

预期关键输出：

```text
Istio core installed
Istiod installed
Ingress gateways installed
secret/istio-remote-secret-cluster2 created
gateway.networking.istio.io/cross-network-gateway created
```

检查 Istio 状态：

```bash
kubectl --context=istio-primary -n istio-system get pods,svc
kubectl --context=istio-remote -n istio-system get pods,svc
```

预期：

```text
pod/istiod-...                  1/1 Running
pod/istio-eastwestgateway-...   1/1 Running
service/istio-eastwestgateway   LoadBalancer ... us-east-1.elb.amazonaws.com
```

## 4. 验证跨集群流量

```bash
scripts/03-verify.sh
```

会部署：

- `istio-primary`：HelloWorld v1、Sleep
- `istio-remote`：HelloWorld v2、Sleep

预期 rollout 输出：

```text
deployment "helloworld-v1" successfully rolled out
deployment "helloworld-v2" successfully rolled out
deployment "sleep" successfully rolled out
```

预期请求结果：

```text
=== Requests from istio-primary ===
Hello version: v1, instance: helloworld-v1-...
Hello version: v2, instance: helloworld-v2-...

=== Requests from istio-remote ===
Hello version: v1, instance: helloworld-v1-...
Hello version: v2, instance: helloworld-v2-...
```

成功标准：

- 从两个集群发起请求都能看到 v1/v2 混合返回
- 两边 sample Pod 均为 `2/2 Running`

手工检查：

```bash
kubectl --context=istio-primary -n sample get pods
kubectl --context=istio-remote -n sample get pods
```

## 5. 清理

```bash
scripts/99-cleanup.sh
```

清理顺序：

1. 删除 `istio-remote`
2. 删除 `istio-primary`

预期输出：

```text
deleting EKS cluster "istio-remote"
deleted cluster "istio-remote"
deleting EKS cluster "istio-primary"
deleted cluster "istio-primary"
```

删除 managed node group、ELB、NAT Gateway、ENI 和 VPC 依赖资源时可能需要数分钟。看到下面输出属于正常：

```text
waiting for CloudFormation stack "eksctl-...-nodegroup-demo"
```

清理后确认：

```bash
aws eks list-clusters --region us-east-1
```

预期不再包含：

```text
istio-primary
istio-remote
```
