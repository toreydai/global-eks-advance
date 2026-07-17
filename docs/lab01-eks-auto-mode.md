# Lab01 — EKS Auto Mode 深度演示

## 实验简介

本实验将完成「EKS Auto Mode 深度演示」的全部操作，属于 EKS 进阶课程，面向有基础集群操作经验的学员。

**实验目标：**
- 掌握 EKS Auto Mode 深度演示 的核心配置与操作流程
- 理解相关组件的架构原理和最佳实践
- 能够独立完成从部署到验证的完整闭环

**实验流程：**
1. 创建 EKS Auto Mode 集群
2. 验证集群初始状态
3. 部署 nginx 应用验证自动节点创建和 NLB
4. 验证 NLB 可访问
5. 创建自定义 Spot NodePool
6. 部署测试工作负载到 Spot NodePool
7. 创建 PVC 验证动态 EBS 卷

**预计 AI 执行时长：** 10-15 分钟


## 前提条件

- **工具**：AWS CLI v2、eksctl（支持 Auto Mode）、kubectl v1.35
- **权限**：AdministratorAccess（含 EKS、EC2、IAM、CloudFormation、ELB、EBS 创建权限）
- **初始化**：

```bash
export AWS_REGION=us-east-1
export AWS_DEFAULT_REGION=us-east-1
export CLUSTER_NAME=demo-auto
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
```

---

## 步骤

### 1. 创建 EKS Auto Mode 集群

```bash
cat > /tmp/auto-cluster.yaml << EOF
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig
metadata:
  name: ${CLUSTER_NAME}
  region: ${AWS_REGION}
  version: "1.35"
iam:
  withOIDC: true
autoModeConfig:
  enabled: true
EOF

eksctl create cluster -f /tmp/auto-cluster.yaml
```

**预期输出**：eksctl 输出集群创建成功，约 15-20 分钟。

> ⚠️ Auto Mode 集群无传统 managed node group，节点按需由 Auto Mode 创建。核心组件（Karpenter、LBC、EBS CSI、Pod Identity Agent）由 EKS 托管管理。

### 2. 验证集群初始状态

```bash
aws eks update-kubeconfig --name ${CLUSTER_NAME} --region ${AWS_REGION}

echo "=== Control Plane 版本 ==="
kubectl version --short 2>/dev/null || kubectl version

echo "=== 初始无节点（Auto Mode 按需创建）==="
kubectl get nodes

echo "=== 内置 NodeClass 和 NodePool ==="
kubectl get nodeclass 2>/dev/null || true
kubectl get nodepool 2>/dev/null || true
```

**预期输出**：初始无节点（或仅系统节点），内置 NodePool 可见。

### 3. 部署 nginx 应用验证自动节点创建和 NLB

> ⚠️ **注意：** EKS Auto Mode 内置 NLB 控制器默认建 `internal`（私有）NLB，从集群 VPC 外部访问会一直超时，不是 DNS 传播延迟的问题。需在 Service 上加注解 `service.beta.kubernetes.io/aws-load-balancer-scheme: internet-facing` 才能建出公网可达的 NLB；若只需集群内/同 VPC 访问，可保留默认的 `internal`，但验证步骤 4 要改用 VPC 内主机测试。

```bash
kubectl apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: auto-nginx
  namespace: default
spec:
  replicas: 2
  selector:
    matchLabels:
      app: auto-nginx
  template:
    metadata:
      labels:
        app: auto-nginx
    spec:
      containers:
      - name: nginx
        image: public.ecr.aws/nginx/nginx:latest
        ports:
        - containerPort: 80
        resources:
          requests:
            cpu: 100m
            memory: 128Mi
---
apiVersion: v1
kind: Service
metadata:
  name: auto-nginx
  namespace: default
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-scheme: internet-facing
spec:
  type: LoadBalancer
  selector:
    app: auto-nginx
  ports:
  - port: 80
    targetPort: 80
EOF

echo "等待 Auto Mode 自动创建节点和 NLB（约 3-5 分钟）..."
kubectl rollout status deployment/auto-nginx --timeout=10m
```

**预期输出**：Auto Mode 自动创建节点，Pod 调度到新节点，NLB 自动创建。

```bash
kubectl get nodes
kubectl get svc auto-nginx
```

**预期输出**：节点由 Auto Mode 创建并 Ready；Service EXTERNAL-IP 出现 NLB 地址。

### 4. 验证 NLB 可访问

```bash
NLB_DNS=$(kubectl get svc auto-nginx -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo "NLB DNS: ${NLB_DNS}"

echo "等待 NLB DNS 传播（约 30 秒）..."
sleep 30

curl -s -o /dev/null -w "HTTP Status: %{http_code}\n" --max-time 10 http://${NLB_DNS}/
```

**预期输出**：`HTTP Status: 200`

### 5. 创建自定义 Spot NodePool

> ⚠️ **注意：** NodePool 的 CRD 是 `karpenter.sh/v1`，不是 `karpenter.k8s.aws/v1`（后者会报 `no matches for kind`）。EKS Auto Mode 节点的实例族标签是 `eks.amazonaws.com/instance-family`，不是社区版 Karpenter 用的 `karpenter.k8s.aws/instance-family`（Auto Mode 节点上不存在该标签，会导致 NodePool 匹配不到节点）。下方已用正确的 group/label。

```bash
kubectl apply -f - <<'EOF'
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: spot-nodepool
spec:
  template:
    spec:
      nodeClassRef:
        group: eks.amazonaws.com
        kind: NodeClass
        name: default
      requirements:
      - key: karpenter.sh/capacity-type
        operator: In
        values: ["spot"]
      - key: eks.amazonaws.com/instance-family
        operator: In
        values: ["t3", "m5", "c5"]
  disruption:
    consolidationPolicy: WhenEmpty
    consolidateAfter: 30s
EOF

kubectl get nodepool spot-nodepool
```

**预期输出**：Spot NodePool 创建成功并 Ready。

### 6. 部署测试工作负载到 Spot NodePool

```bash
kubectl apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: spot-test
  namespace: default
spec:
  replicas: 2
  selector:
    matchLabels:
      app: spot-test
  template:
    metadata:
      labels:
        app: spot-test
    spec:
      nodeSelector:
        karpenter.sh/capacity-type: spot
      tolerations:
      - key: karpenter.sh/capacity-type
        value: spot
        effect: NoSchedule
      containers:
      - name: app
        image: public.ecr.aws/docker/library/busybox:latest
        command: ["sleep", "3600"]
        resources:
          requests:
            cpu: 100m
            memory: 64Mi
EOF

kubectl rollout status deployment/spot-test --timeout=10m
echo "Spot 工作负载已部署"
```

**预期输出**：打印"Spot 工作负载已部署"

### 7. 创建 PVC 验证动态 EBS 卷

```bash
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: auto-pvc
  namespace: default
spec:
  accessModes:
  - ReadWriteOnce
  storageClassName: auto-ebs-sc
  resources:
    requests:
      storage: 5Gi
---
apiVersion: v1
kind: Pod
metadata:
  name: pvc-test
  namespace: default
spec:
  containers:
  - name: app
    image: public.ecr.aws/docker/library/busybox:latest
    command: ["sleep", "3600"]
    volumeMounts:
    - name: data
      mountPath: /data
    resources:
      requests:
        cpu: 100m
        memory: 64Mi
  volumes:
  - name: data
    persistentVolumeClaim:
      claimName: auto-pvc
EOF

kubectl wait --for=condition=Bound pvc/auto-pvc --timeout=5m
echo "PVC 已绑定"
```

**预期输出**：打印"PVC 已绑定"，Auto Mode 自动创建并挂载 EBS 卷。

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
| 1 | `aws eks describe-cluster --name demo-auto --region us-east-1 --query 'cluster.status' --output text` | `ACTIVE` |
| 2 | `kubectl get nodepool --no-headers \| wc -l \| tr -d ' '` | 至少 `2`（含内置和 spot-nodepool） |
| 3 | `kubectl get pvc auto-pvc -o jsonpath='{.status.phase}'` | `Bound` |
| 4 | `kubectl get pods -l app=auto-nginx --no-headers \| grep Running \| wc -l \| tr -d ' '` | `2` |

---

## 实验总结

本实验完成了「EKS Auto Mode 深度演示」的全部操作，从资源创建到功能验证形成了完整闭环。通过动手实践，你已掌握了相关组件在生产环境中的核心配置方法和最佳实践。Lab02 将学习多集群管理与 ArgoCD。

---

## 清理

```bash
kubectl delete deployment spot-test auto-nginx 2>/dev/null || true
kubectl delete service auto-nginx 2>/dev/null || true
kubectl delete pod pvc-test 2>/dev/null || true
kubectl delete pvc auto-pvc 2>/dev/null || true
kubectl delete nodepool spot-nodepool 2>/dev/null || true

echo "等待节点自动回收（约 2-3 分钟）..."
sleep 60

eksctl delete cluster --name ${CLUSTER_NAME} --region ${AWS_REGION}
echo "清理完成"
```
