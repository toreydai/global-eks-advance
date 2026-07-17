# Lab03 — Kubecost 成本优化

## 实验简介

本实验将完成「Kubecost 成本优化」的全部操作，属于 EKS 进阶课程，面向有基础集群操作经验的学员。

**实验目标：**
- 掌握 Kubecost 成本优化 的核心配置与操作流程
- 理解相关组件的架构原理和最佳实践
- 能够独立完成从部署到验证的完整闭环

**实验流程：**
1. 安装 Kubecost
2. 验证 Kubecost 运行状态
3. 部署三类对比工作负载
4. 访问 Kubecost UI
5. 可选：Karpenter Spot NodePool 降本演示

**预计 AI 执行时长：** 8-10 分钟


## 前提条件

- **工具**：AWS CLI v2、kubectl v1.35、Helm v3
- **权限**：AdministratorAccess（含 EKS、IAM、Cost Explorer、ELB 创建权限）
- **前提**：EKS QuickStart 集群可用（`demo` 集群）
- **初始化**：

```bash
export AWS_REGION=us-east-1
export AWS_DEFAULT_REGION=us-east-1
export CLUSTER_NAME=demo
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
```

---

## 步骤

### 1. 安装 Kubecost

```bash
helm repo add kubecost https://kubecost.github.io/cost-analyzer/
helm repo update

helm upgrade --install kubecost kubecost/cost-analyzer \
  --namespace kubecost \
  --create-namespace \
  --version 2.8.6 \
  --set kubecostToken="not-required-for-demo" \
  --set persistentVolume.storageClass=ebs-sc \
  --set prometheus.server.persistentVolume.storageClass=ebs-sc \
  --set prometheus.alertmanager.persistentVolume.storageClass=ebs-sc \
  --wait \
  --timeout 5m

kubectl rollout status deployment/kubecost-cost-analyzer -n kubecost --timeout=5m
echo "Kubecost 安装完成"
```

**预期输出**：打印"Kubecost 安装完成"

> **注意：** 不指定 `--version` 会拉到 `kubecost/cost-analyzer` 2.9.x（面向 3.0 联邦存储架构的过渡版本），单机 demo 场景下会连续报 `clusterId is required`/`Missing global federated-store` 等错误。已改为显式 `--version 2.8.6`（最后一个独立单集群模式的稳定版本）。
>
> **注意：** 集群没有标记 `(default)` 的 StorageClass，chart 默认不给 PVC 设置 `storageClassName`，会导致 PVC 一直 `Pending` 直至 `helm --wait` 超时。已通过 `--set persistentVolume.storageClass=ebs-sc` 等三处显式指定 EBS CSI StorageClass；若后续把 `ebs-sc` 设为集群默认，可省略这些 `--set`。
>
> **已验证（多 agent 并发安全）：** 若操作机上同时存在多个集群的 kubeconfig context（例如与其他 Lab 并行执行），执行 `aws eks update-kubeconfig` 会覆盖 `~/.kube/config` 的 `current-context`。本实验所有 `kubectl`/`helm` 命令都应显式带 `--context <本实验集群 context>`（helm 对应 `--kube-context`），不要依赖 current-context，避免误操作到其他并行任务正在使用的集群或资源。

### 2. 验证 Kubecost 运行状态

```bash
kubectl get pods -n kubecost
kubectl get svc -n kubecost
```

**预期输出**：cost-analyzer、prometheus、grafana 等 Pod Running；Service 可见。

### 3. 部署三类对比工作负载

```bash
kubectl create namespace cost-demo 2>/dev/null || true

kubectl apply -n cost-demo -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: overprovisioned
spec:
  replicas: 3
  selector:
    matchLabels:
      app: overprovisioned
  template:
    metadata:
      labels:
        app: overprovisioned
    spec:
      containers:
      - name: app
        image: public.ecr.aws/docker/library/nginx:alpine
        resources:
          requests:
            cpu: 500m
            memory: 512Mi
          limits:
            cpu: "2"
            memory: 2Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: rightsized
spec:
  replicas: 2
  selector:
    matchLabels:
      app: rightsized
  template:
    metadata:
      labels:
        app: rightsized
    spec:
      containers:
      - name: app
        image: public.ecr.aws/docker/library/nginx:alpine
        resources:
          requests:
            cpu: 100m
            memory: 128Mi
          limits:
            cpu: 200m
            memory: 256Mi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: idle-replica
spec:
  replicas: 5
  selector:
    matchLabels:
      app: idle-replica
  template:
    metadata:
      labels:
        app: idle-replica
    spec:
      containers:
      - name: app
        image: public.ecr.aws/docker/library/busybox:latest
        command: ["sleep", "3600"]
        resources:
          requests:
            cpu: 50m
            memory: 64Mi
EOF

kubectl rollout status deployment/overprovisioned -n cost-demo --timeout=3m
kubectl rollout status deployment/rightsized -n cost-demo --timeout=3m
kubectl rollout status deployment/idle-replica -n cost-demo --timeout=3m
echo "示例工作负载已部署"
```

**预期输出**：打印"示例工作负载已部署"

### 4. 访问 Kubecost UI

```bash
echo "=== 通过 port-forward 访问 Kubecost UI ==="
echo "在另一个终端运行：kubectl port-forward -n kubecost svc/kubecost-cost-analyzer 9090:9090"
echo "浏览器访问：http://localhost:9090"

echo ""
echo "=== 查看 cost-demo namespace 工作负载 ==="
kubectl get pods -n cost-demo -o wide
```

> ⚠️ Kubecost 成本数据通常有 1-2 小时延迟。首次安装后，成本视图需等待约 30 分钟生效。

### 5. 可选：Karpenter Spot NodePool 降本演示

```bash
kubectl apply -f - <<'EOF'
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: spot-cost-demo
spec:
  template:
    spec:
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: default
      requirements:
      - key: karpenter.sh/capacity-type
        operator: In
        values: ["spot"]
      - key: kubernetes.io/arch
        operator: In
        values: ["amd64"]
  limits:
    cpu: "16"
  disruption:
    consolidationPolicy: WhenEmpty
    consolidateAfter: 30s
EOF

echo "=== Spot NodePool 已创建（需要 Karpenter 已安装）==="
kubectl get nodepool spot-cost-demo 2>/dev/null || echo "Karpenter 未安装，跳过 Spot NodePool"
```

---

## 验收标准

完成本实验后，你应当能够：
- [ ] 所有核心资源创建成功且状态正常
- [ ] 验证检查点中的所有命令返回预期结果
- [ ] 理解各组件的架构关系和配置要点

---

## 验证检查点

| # | 检查命令 | 期望精确输出 |
|---|---------|-------------|
| 1 | `kubectl get pods -n kubecost --no-headers \| grep Running \| wc -l \| tr -d ' '` | 至少 `3` |
| 2 | `kubectl get deployment kubecost-cost-analyzer -n kubecost -o jsonpath='{.status.readyReplicas}'` | `1` |
| 3 | `kubectl get pods -n cost-demo --no-headers \| grep Running \| wc -l \| tr -d ' '` | `10` |
| 4 | `kubectl get deployment overprovisioned -n cost-demo -o jsonpath='{.status.readyReplicas}'` | `3` |

---

## 实验总结

本实验完成了「Kubecost 成本优化」的全部操作，从资源创建到功能验证形成了完整闭环。通过动手实践，你已掌握了相关组件在生产环境中的核心配置方法和最佳实践。Lab04 将学习在 EKS 上部署 AI Agent。

---

## 清理

```bash
kubectl delete namespace cost-demo 2>/dev/null || true
kubectl delete nodepool spot-cost-demo 2>/dev/null || true

helm uninstall kubecost -n kubecost 2>/dev/null || true
kubectl delete namespace kubecost 2>/dev/null || true

echo "清理完成"
```
