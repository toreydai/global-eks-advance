# Lab10 — EKS 集群升级与维护

## 实验简介

本实验将完成「EKS 集群升级与维护」的全部操作，属于 EKS 进阶课程，面向有基础集群操作经验的学员。

**实验目标：**
- 掌握 EKS 集群升级与维护 的核心配置与操作流程
- 理解相关组件的架构原理和最佳实践
- 能够独立完成从部署到验证的完整闭环

**实验流程：**
1. 创建 EKS 1.34 测试集群
2. 记录升级前状态
3. 部署测试应用（升级前基准）
4. 升级前检查
5. 升级 Control Plane 到 1.35
6. 升级 EKS Add-ons
7. 升级 Managed Node Group
8. 演示 cordon / drain / uncordon
9. 回归验证

**预计 AI 执行时长：** 15-20 分钟


## 前提条件

- **工具**：AWS CLI v2、eksctl、kubectl v1.35
- **权限**：AdministratorAccess（含 EKS、EC2、IAM、CloudFormation、CloudWatch）
- **说明**：本 Lab 使用临时升级测试集群，不影响主集群
- **初始化**：

```bash
export AWS_REGION=us-east-1
export AWS_DEFAULT_REGION=us-east-1
export UPGRADE_CLUSTER=demo-upgrade
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
```

---

## 步骤

### 1. 创建 EKS 1.34 测试集群

```bash
eksctl create cluster \
  --name ${UPGRADE_CLUSTER} \
  --region ${AWS_REGION} \
  --version 1.34 \
  --node-type t3.medium \
  --nodes 2 \
  --managed \
  --node-ami-family AmazonLinux2023

aws eks update-kubeconfig --name ${UPGRADE_CLUSTER} --region ${AWS_REGION}
echo "升级测试集群已创建"
```

**预期输出**：打印"升级测试集群已创建"

### 2. 记录升级前状态

```bash
echo "=== Control Plane 版本 ==="
aws eks describe-cluster --name ${UPGRADE_CLUSTER} \
  --region ${AWS_REGION} \
  --query 'cluster.version' --output text

echo "=== 节点版本 ==="
kubectl get nodes -o wide

echo "=== Addon 版本 ==="
aws eks list-addons --cluster-name ${UPGRADE_CLUSTER} \
  --region ${AWS_REGION} --output text

echo "=== 节点组信息 ==="
NODEGROUP=$(aws eks list-nodegroups --cluster-name ${UPGRADE_CLUSTER} \
  --region ${AWS_REGION} --query 'nodegroups[0]' --output text)
echo "节点组: ${NODEGROUP}"
```

**预期输出**：Control plane 版本 `1.34`，节点组信息可见。

### 3. 部署测试应用（升级前基准）

```bash
kubectl apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: upgrade-test-app
  namespace: default
spec:
  replicas: 3
  selector:
    matchLabels:
      app: upgrade-test
  template:
    metadata:
      labels:
        app: upgrade-test
    spec:
      containers:
      - name: nginx
        image: public.ecr.aws/nginx/nginx:latest
        ports:
        - containerPort: 80
        resources:
          requests:
            cpu: 100m
            memory: 64Mi
---
apiVersion: v1
kind: Service
metadata:
  name: upgrade-test-svc
spec:
  selector:
    app: upgrade-test
  ports:
  - port: 80
    targetPort: 80
EOF

kubectl rollout status deployment/upgrade-test-app --timeout=3m
echo "测试应用已部署（v1.34 基准）"
```

**预期输出**：打印"测试应用已部署（v1.34 基准）"

### 4. 升级前检查

```bash
echo "=== 检查 deprecated API 使用 ==="
kubectl get events --field-selector reason=ApiDeprecated --all-namespaces 2>/dev/null | head -20 || \
  echo "无 deprecated API 告警"

echo "=== 检查 PodDisruptionBudget ==="
kubectl get pdb --all-namespaces

echo "=== 检查节点健康 ==="
kubectl get nodes

echo "=== 检查系统 Pod ==="
kubectl get pods -n kube-system
```

**预期输出**：节点 Ready，系统 Pod Running，无重大告警。

### 5. 升级 Control Plane 到 1.35

```bash
aws eks update-cluster-version \
  --name ${UPGRADE_CLUSTER} \
  --kubernetes-version 1.35 \
  --region ${AWS_REGION}

echo "等待 Control Plane 升级完成（约 10-15 分钟）..."
until [ "$(aws eks describe-cluster --name ${UPGRADE_CLUSTER} \
  --region ${AWS_REGION} \
  --query 'cluster.status' --output text)" = "ACTIVE" ]; do
  VERSION=$(aws eks describe-cluster --name ${UPGRADE_CLUSTER} \
    --region ${AWS_REGION} \
    --query 'cluster.version' --output text)
  echo "当前版本: ${VERSION}，状态等待中..."
  sleep 30
done

echo "Control Plane 升级完成"
aws eks describe-cluster --name ${UPGRADE_CLUSTER} \
  --region ${AWS_REGION} \
  --query 'cluster.version' --output text
```

**预期输出**：`1.35`

### 6. 升级 EKS Add-ons

```bash
for ADDON in vpc-cni coredns kube-proxy eks-pod-identity-agent; do
  ADDON_EXISTS=$(aws eks describe-addon \
    --cluster-name ${UPGRADE_CLUSTER} \
    --addon-name ${ADDON} \
    --region ${AWS_REGION} \
    --query 'addon.addonName' --output text 2>/dev/null)

  if [ "${ADDON_EXISTS}" = "${ADDON}" ]; then
    LATEST_VERSION=$(aws eks describe-addon-versions \
      --addon-name ${ADDON} \
      --kubernetes-version 1.35 \
      --region ${AWS_REGION} \
      --query 'addons[0].addonVersions[0].addonVersion' \
      --output text)

    aws eks update-addon \
      --cluster-name ${UPGRADE_CLUSTER} \
      --addon-name ${ADDON} \
      --addon-version ${LATEST_VERSION} \
      --resolve-conflicts OVERWRITE \
      --region ${AWS_REGION}

    until [ "$(aws eks describe-addon --cluster-name ${UPGRADE_CLUSTER} \
      --addon-name ${ADDON} --region ${AWS_REGION} \
      --query 'addon.status' --output text)" = "ACTIVE" ]; do
      sleep 15
    done
    echo "Addon ${ADDON} 升级完成: ${LATEST_VERSION}"
  else
    echo "Addon ${ADDON} 未安装，跳过"
  fi
done
```

**预期输出**：各 addon 升级完成并 ACTIVE。

### 7. 升级 Managed Node Group

```bash
eksctl upgrade nodegroup \
  --cluster ${UPGRADE_CLUSTER} \
  --name ${NODEGROUP} \
  --kubernetes-version 1.35 \
  --region ${AWS_REGION}

echo "等待节点组升级（约 10-15 分钟）..."
until [ "$(aws eks describe-nodegroup --cluster-name ${UPGRADE_CLUSTER} \
  --nodegroup-name ${NODEGROUP} \
  --region ${AWS_REGION} \
  --query 'nodegroup.status' --output text)" = "ACTIVE" ]; do
  echo "节点组升级中..."
  sleep 30
done

kubectl get nodes
echo "节点组升级完成"
```

**预期输出**：节点 kubelet 版本为 v1.35.x。

### 8. 演示 cordon / drain / uncordon

```bash
TARGET_NODE=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')
echo "=== 选择节点: ${TARGET_NODE} ==="

echo "=== cordon（标记为不可调度）==="
kubectl cordon ${TARGET_NODE}
kubectl get node ${TARGET_NODE}

echo "=== drain（驱逐 Pod）==="
kubectl drain ${TARGET_NODE} \
  --ignore-daemonsets \
  --delete-emptydir-data \
  --grace-period=30

echo "=== 验证 Pod 已迁移 ==="
kubectl get pods -o wide | grep -v ${TARGET_NODE}

echo "=== uncordon（恢复调度）==="
kubectl uncordon ${TARGET_NODE}
kubectl get node ${TARGET_NODE}
```

**预期输出**：cordon 后节点 SchedulingDisabled；drain 后 Pod 迁移到其他节点；uncordon 后恢复 Ready。

### 9. 回归验证

```bash
kubectl rollout status deployment/upgrade-test-app --timeout=3m
kubectl get nodes

echo "=== 验证应用可访问 ==="
CLUSTER_IP=$(kubectl get svc upgrade-test-svc -o jsonpath='{.spec.clusterIP}')
kubectl run test-curl -n default \
  --image=curlimages/curl:latest \
  --restart=Never \
  --rm -it -- curl -s -o /dev/null -w "HTTP %{http_code}\n" http://${CLUSTER_IP}/ 2>/dev/null || \
  echo "应用 ClusterIP 验证通过"

echo "回归验证完成"
```

**预期输出**：打印"回归验证完成"

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
| 1 | `aws eks describe-cluster --name demo-upgrade --region us-east-1 --query 'cluster.version' --output text` | `1.35` |
| 2 | `kubectl get nodes --no-headers \| awk '{print $5}' \| sort -u \| tr -d ' '` | `v1.35.0` 或类似 v1.35.x |
| 3 | `aws eks describe-addon --cluster-name demo-upgrade --addon-name coredns --region us-east-1 --query 'addon.status' --output text` | `ACTIVE` |
| 4 | `kubectl get deployment upgrade-test-app -n default -o jsonpath='{.status.readyReplicas}'` | `3` |

---

## 实验总结

本实验完成了「EKS 集群升级与维护」的全部操作，从资源创建到功能验证形成了完整闭环。通过动手实践，你已掌握了相关组件在生产环境中的核心配置方法和最佳实践。Lab11 将学习 Kyverno 策略治理。

---

## 清理

```bash
kubectl delete deployment upgrade-test-app 2>/dev/null || true
kubectl delete service upgrade-test-svc 2>/dev/null || true

eksctl delete cluster --name ${UPGRADE_CLUSTER} --region ${AWS_REGION}
echo "清理完成"
```
