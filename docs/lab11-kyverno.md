# Lab11 — Kyverno 策略治理

## 实验简介

本实验将完成「Kyverno 策略治理」的全部操作，属于 EKS 进阶课程，面向有基础集群操作经验的学员。

**实验目标：**
- 掌握 Kyverno 策略治理 的核心配置与操作流程
- 理解相关组件的架构原理和最佳实践
- 能够独立完成从部署到验证的完整闭环

**实验流程：**
1. 安装 Kyverno
2. 验证 Kyverno Pod 状态
3. 创建测试 namespace
4. 创建 ClusterPolicy（要求配置 resources）
5. 验证不合规 Pod 被拒绝
6. 验证合规 Pod 创建成功
7. 查看策略报告和事件
8. 测试 Audit 模式对比

**预计 AI 执行时长：** 8-10 分钟


## 前提条件

- **工具**：AWS CLI v2、kubectl v1.35、Helm v3
- **权限**：EKS 集群管理员权限
- **前提**：EKS 集群可用，Helm 已安装
- **初始化**：

```bash
export AWS_REGION=us-east-1
export AWS_DEFAULT_REGION=us-east-1
export CLUSTER_NAME=demo
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
```

---

## 背景：Kyverno 策略模式

| 模式 | 效果 | 适用场景 |
|------|------|---------|
| Enforce | 直接拒绝不合规资源 | 演示环境、严格管控 |
| Audit | 记录违规但不阻断 | 生产环境前期观测 |

---

## 步骤

### 1. 安装 Kyverno

```bash
helm repo add kyverno https://kyverno.github.io/kyverno/
helm repo update

helm upgrade --install kyverno kyverno/kyverno \
  --namespace kyverno \
  --create-namespace \
  --wait \
  --timeout 5m

kubectl rollout status deployment/kyverno-admission-controller \
  -n kyverno --timeout=5m
echo "Kyverno 安装完成"
```

**预期输出**：打印"Kyverno 安装完成"

### 2. 验证 Kyverno Pod 状态

```bash
kubectl get pods -n kyverno
```

**预期输出**：admission-controller、background-controller、cleanup-controller、reports-controller 等 Pod 均为 Running。

### 3. 创建测试 namespace

```bash
kubectl create namespace policy-demo
echo "测试 namespace 已创建"
```

**预期输出**：打印"测试 namespace 已创建"

### 4. 创建 ClusterPolicy（要求配置 resources）

```bash
kubectl apply -f - <<'EOF'
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-resources
spec:
  validationFailureAction: Enforce
  background: true
  rules:
  - name: require-cpu-memory-requests-limits
    match:
      any:
      - resources:
          kinds:
          - Pod
    exclude:
      any:
      - resources:
          namespaces:
          - kube-system
          - kyverno
          - kube-public
    validate:
      message: "Pod 必须配置 resources.requests 和 resources.limits（cpu 和 memory）。"
      pattern:
        spec:
          containers:
          - name: "*"
            resources:
              requests:
                cpu: "?*"
                memory: "?*"
              limits:
                cpu: "?*"
                memory: "?*"
EOF

kubectl get clusterpolicy require-resources
echo "ClusterPolicy 已创建"
```

**预期输出**：ClusterPolicy Ready，打印"ClusterPolicy 已创建"

### 5. 验证不合规 Pod 被拒绝

```bash
echo "=== 尝试创建不带 resources 的 Pod（expect: Forbidden）==="
kubectl apply -n policy-demo -f - <<'EOF' 2>&1 || true
apiVersion: v1
kind: Pod
metadata:
  name: bad-pod
spec:
  containers:
  - name: nginx
    image: public.ecr.aws/nginx/nginx:latest
EOF
```

**预期输出**：`admission webhook ... denied the request: Pod 必须配置 resources.requests 和 resources.limits`

### 6. 验证合规 Pod 创建成功

```bash
echo "=== 创建带 resources 的合规 Pod（expect: 创建成功）==="
kubectl apply -n policy-demo -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: good-pod
spec:
  containers:
  - name: nginx
    image: public.ecr.aws/nginx/nginx:latest
    resources:
      requests:
        cpu: 100m
        memory: 128Mi
      limits:
        cpu: 200m
        memory: 256Mi
EOF

kubectl wait --for=condition=Ready pod/good-pod -n policy-demo --timeout=60s
echo "合规 Pod 创建成功并 Running"
```

**预期输出**：打印"合规 Pod 创建成功并 Running"

### 7. 查看策略报告和事件

```bash
echo "=== 策略报告 ==="
kubectl get policyreport -A 2>/dev/null || echo "等待策略报告生成..."

echo "=== Kyverno 准入事件 ==="
kubectl get events -n policy-demo --field-selector reason=PolicyViolation 2>/dev/null | head -10 || true

echo "=== ClusterPolicy 详细状态 ==="
kubectl describe clusterpolicy require-resources | grep -A 5 "Status"
```

**预期输出**：策略报告可见，违规事件有记录。

### 8. 测试 Audit 模式对比

```bash
kubectl apply -f - <<'EOF'
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: audit-image-tag
spec:
  validationFailureAction: Audit
  background: true
  rules:
  - name: require-image-tag
    match:
      any:
      - resources:
          kinds:
          - Pod
    exclude:
      any:
      - resources:
          namespaces:
          - kube-system
          - kyverno
    validate:
      message: "镜像必须指定非 latest 的 tag（Audit 模式，仅记录不阻断）。"
      pattern:
        spec:
          containers:
          - name: "*"
            image: "!*:latest"
EOF

echo "=== 使用 latest tag（Audit 模式下允许创建，但会记录违规）==="
kubectl apply -n policy-demo -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: audit-test-pod
spec:
  containers:
  - name: nginx
    image: public.ecr.aws/nginx/nginx:latest
    resources:
      requests:
        cpu: 50m
        memory: 64Mi
      limits:
        cpu: 100m
        memory: 128Mi
EOF

kubectl get pod audit-test-pod -n policy-demo
echo "Audit 模式：Pod 已创建，违规被记录而不阻断"
```

**预期输出**：Pod 创建成功（Audit 不阻断），打印"违规被记录而不阻断"

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
| 1 | `kubectl get pods -n kyverno --no-headers \| grep Running \| wc -l \| tr -d ' '` | 至少 `4` |
| 2 | `kubectl get clusterpolicy require-resources -o jsonpath='{.spec.validationFailureAction}'` | `Enforce` |
| 3 | `kubectl get pod good-pod -n policy-demo -o jsonpath='{.status.phase}'` | `Running` |
| 4 | `kubectl get pod bad-pod -n policy-demo 2>&1 \| grep -c 'NotFound\|not found'` | `1` |

---

## 实验总结

本实验完成了「Kyverno 策略治理」的全部操作，从资源创建到功能验证形成了完整闭环。通过动手实践，你已掌握了相关组件在生产环境中的核心配置方法和最佳实践。Lab12 将学习 Istio 服务网格。

---

## 清理

```bash
kubectl delete clusterpolicy require-resources audit-image-tag 2>/dev/null || true
kubectl delete namespace policy-demo 2>/dev/null || true

helm uninstall kyverno -n kyverno 2>/dev/null || true
kubectl delete namespace kyverno 2>/dev/null || true

echo "清理完成"
```
