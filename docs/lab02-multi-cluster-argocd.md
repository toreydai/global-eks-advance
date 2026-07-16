# Lab02 — 多集群管理（Argo CD Hub-Spoke）

## 实验简介

本实验将完成「多集群管理与 ArgoCD」的全部操作，属于 EKS 进阶课程，面向有基础集群操作经验的学员。

**实验目标：**
- 掌握 多集群管理与 ArgoCD 的核心配置与操作流程
- 理解相关组件的架构原理和最佳实践
- 能够独立完成从部署到验证的完整闭环

**实验流程：**
1. 确认 Hub 集群并创建 Spoke 集群
2. 在 Hub 集群安装 Argo CD
3. 安装 argocd CLI 并登录
4. 注册 Spoke 集群到 Argo CD
5. 创建跨集群统一 IAM 运维角色
6. 使用 ApplicationSet 多集群发布 Guestbook

**预计 AI 执行时长：** 10-12 分钟


## 前提条件

- **工具**：AWS CLI v2、eksctl、kubectl v1.35、Helm v3、argocd CLI
- **权限**：AdministratorAccess（含 EKS、EC2、IAM、CloudFormation、ELB、Secrets Manager 创建权限）
- **前提**：至少 1 个 EKS 1.35 集群作为 Hub（本 Lab 会创建 Spoke 集群）
- **初始化**：

```bash
export AWS_REGION=us-east-1
export AWS_DEFAULT_REGION=us-east-1
export CLUSTER_NAME=demo
export SPOKE_CLUSTER=demo-spoke
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
```

---

## 步骤

### 1. 确认 Hub 集群并创建 Spoke 集群

```bash
aws eks update-kubeconfig --name ${CLUSTER_NAME} --region ${AWS_REGION}
kubectl config rename-context $(kubectl config current-context) hub

echo "=== Hub 集群版本 ==="
kubectl version --short 2>/dev/null | grep Server || kubectl version | grep "Server Version"

eksctl create cluster \
  --name ${SPOKE_CLUSTER} \
  --region ${AWS_REGION} \
  --version 1.35 \
  --node-type t3.medium \
  --nodes 2 \
  --managed \
  --node-ami-family AmazonLinux2023

aws eks update-kubeconfig --name ${SPOKE_CLUSTER} --region ${AWS_REGION}
kubectl config rename-context $(kubectl config current-context) spoke

echo "=== 切换回 Hub ==="
kubectl config use-context hub
kubectl get nodes
```

**预期输出**：两个集群均可访问，Hub 节点 Ready。

### 2. 在 Hub 集群安装 Argo CD

```bash
kubectl config use-context hub

kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

kubectl rollout status deployment/argocd-server -n argocd --timeout=5m
echo "Argo CD 安装完成"
```

**预期输出**：打印"Argo CD 安装完成"

### 3. 安装 argocd CLI 并登录

```bash
ARGOCD_VERSION=$(curl -s https://api.github.com/repos/argoproj/argo-cd/releases/latest | jq -r '.tag_name' 2>/dev/null || echo "v2.14.0")
curl -sSL -o /usr/local/bin/argocd \
  "https://github.com/argoproj/argo-cd/releases/download/${ARGOCD_VERSION}/argocd-linux-amd64" 2>/dev/null || \
curl -sSL -o /usr/local/bin/argocd \
  "https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64"
chmod +x /usr/local/bin/argocd

kubectl patch svc argocd-server -n argocd -p '{"spec":{"type":"LoadBalancer"}}'
echo "等待 Argo CD LB 地址..."
sleep 30

ARGOCD_LB=$(kubectl get svc argocd-server -n argocd \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo "Argo CD LB: ${ARGOCD_LB}"

ARGOCD_PASS=$(kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d)

argocd login ${ARGOCD_LB} \
  --username admin \
  --password ${ARGOCD_PASS} \
  --insecure \
  --grpc-web

echo "Argo CD 登录成功"
```

**预期输出**：打印"Argo CD 登录成功"

### 4. 注册 Spoke 集群到 Argo CD

```bash
kubectl config use-context hub
SPOKE_SERVER=$(aws eks describe-cluster --name ${SPOKE_CLUSTER} \
  --region ${AWS_REGION} --query 'cluster.endpoint' --output text)

argocd cluster add spoke --name spoke-cluster --yes

argocd cluster list
```

**预期输出**：Argo CD cluster list 显示 Hub（in-cluster）和 Spoke 集群。

### 5. 创建跨集群统一 IAM 运维角色

```bash
cat > /tmp/ops-trust.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {
      "AWS": "arn:aws:iam::${ACCOUNT_ID}:root"
    },
    "Action": "sts:AssumeRole"
  }]
}
EOF

OPS_ROLE_ARN=$(aws iam create-role \
  --role-name EKS-MultiCluster-OpsRole \
  --assume-role-policy-document file:///tmp/ops-trust.json \
  --query Role.Arn --output text)

for CLUSTER in ${CLUSTER_NAME} ${SPOKE_CLUSTER}; do
  aws eks create-access-entry \
    --cluster-name ${CLUSTER} \
    --principal-arn ${OPS_ROLE_ARN} \
    --type STANDARD \
    --region ${AWS_REGION}

  aws eks associate-access-policy \
    --cluster-name ${CLUSTER} \
    --principal-arn ${OPS_ROLE_ARN} \
    --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy \
    --access-scope type=cluster \
    --region ${AWS_REGION}

  echo "已为 ${CLUSTER} 创建 Access Entry"
done
```

**预期输出**：两个集群均打印"已为 xxx 创建 Access Entry"

### 6. 使用 ApplicationSet 多集群发布 Guestbook

```bash
kubectl config use-context hub

kubectl apply -n argocd -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: guestbook-multicluster
spec:
  generators:
  - list:
      elements:
      - cluster: in-cluster
        url: https://kubernetes.default.svc
      - cluster: spoke-cluster
        url: ${SPOKE_SERVER}
  template:
    metadata:
      name: 'guestbook-{{cluster}}'
    spec:
      project: default
      source:
        repoURL: https://github.com/argoproj/argocd-example-apps.git
        targetRevision: HEAD
        path: guestbook
      destination:
        server: '{{url}}'
        namespace: guestbook
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
        - CreateNamespace=true
EOF

echo "等待 ApplicationSet 同步（约 2-3 分钟）..."
sleep 60
argocd app list
```

**预期输出**：两个 Application（guestbook-in-cluster 和 guestbook-spoke-cluster）均 Synced + Healthy。

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
| 1 | `kubectl get pods -n argocd --no-headers \| grep Running \| wc -l \| tr -d ' '` | 至少 `5` |
| 2 | `argocd cluster list --output json 2>/dev/null \| jq 'length'` | `2` |
| 3 | `aws eks describe-access-entry --cluster-name demo --principal-arn arn:aws:iam::$(aws sts get-caller-identity --query Account --output text):role/EKS-MultiCluster-OpsRole --region us-east-1 --query 'accessEntry.type' --output text` | `STANDARD` |
| 4 | `kubectl --context spoke get pods -n guestbook --no-headers \| grep Running \| wc -l \| tr -d ' '` | 至少 `1` |

---

## 实验总结

本实验完成了「多集群管理与 ArgoCD」的全部操作，从资源创建到功能验证形成了完整闭环。通过动手实践，你已掌握了相关组件在生产环境中的核心配置方法和最佳实践。Lab03 将学习 Kubecost 成本优化。

---

## 清理

```bash
kubectl config use-context hub

argocd app delete guestbook-in-cluster --yes 2>/dev/null || true
argocd app delete guestbook-spoke-cluster --yes 2>/dev/null || true
kubectl delete applicationset guestbook-multicluster -n argocd 2>/dev/null || true

for CLUSTER in ${CLUSTER_NAME} ${SPOKE_CLUSTER}; do
  aws eks delete-access-entry \
    --cluster-name ${CLUSTER} \
    --principal-arn "arn:aws:iam::${ACCOUNT_ID}:role/EKS-MultiCluster-OpsRole" \
    --region ${AWS_REGION} 2>/dev/null || true
done

aws iam delete-role --role-name EKS-MultiCluster-OpsRole 2>/dev/null || true

kubectl delete -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml 2>/dev/null || true
kubectl delete namespace argocd 2>/dev/null || true

eksctl delete cluster --name ${SPOKE_CLUSTER} --region ${AWS_REGION}

echo "清理完成"
```
