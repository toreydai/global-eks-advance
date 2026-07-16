# Lab12 — Istio 服务网格

## 实验简介

本实验将完成「Istio 服务网格」的全部操作，属于 EKS 进阶课程，面向有基础集群操作经验的学员。

**实验目标：**
- 掌握 Istio 服务网格 的核心配置与操作流程
- 理解相关组件的架构原理和最佳实践
- 能够独立完成从部署到验证的完整闭环

**实验流程：**
1. 安装 istioctl
2. 安装 Istio 控制面
3. 创建并标记 istio-demo namespace
4. 部署 Bookinfo 示例应用
5. 创建 Ingress Gateway 暴露 Bookinfo
6. 金丝雀流量管理（VirtualService + DestinationRule）
7. 启用 mTLS（PeerAuthentication STRICT）
8. AuthorizationPolicy 服务间授权

**预计 AI 执行时长：** 12-15 分钟


## 前提条件

- **工具**：AWS CLI v2、kubectl v1.35、curl
- **权限**：EKS 集群管理员权限，ELB 创建权限
- **前提**：EKS 集群可用，**使用独立 namespace `istio-demo`，不复用生产 namespace**
- **初始化**：

```bash
export AWS_REGION=us-east-1
export AWS_DEFAULT_REGION=us-east-1
export CLUSTER_NAME=demo
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export ISTIO_NS=istio-demo
```

> **已验证：** Istio 会在集群级别安装 CRD、MutatingWebhookConfiguration/ValidatingWebhookConfiguration 和控制面组件，与共享集群 `demo` 上并行运行的其他实验（不同的节点组、CRD、准入 webhook）存在冲突风险。**强烈建议改为创建独立临时集群**（例如 `demo-istio`，EKS 1.35，managed node group，t3.medium x2，参考 `docs/lab01-eks-auto-mode.md` 中 `eksctl create cluster` 的写法），并将 `CLUSTER_NAME` 指向该临时集群；实验结束后除了清理 Istio 组件外，还需 `eksctl delete cluster` 删除整个临时集群。
>
> **已验证：** 若操作机上同时有多个集群的 kubeconfig context（例如并行执行其他 Lab），`aws eks update-kubeconfig` 会反复覆盖 `~/.kube/config` 的 `current-context`。若本实验的 `kubectl`/`istioctl` 命令不显式指定 `--context`，存在连到错误集群的风险（实测复现：install 命令曾在 current-context 被并发任务翻转后误装到另一个集群，需要立即 `istioctl uninstall --purge --context <该集群>` 回滚）。**建议所有命令都显式带 `--context <本实验集群 context>`，不要依赖 current-context。**

---

## 步骤

### 1. 安装 istioctl

> **已验证：** 原 `sed 's/.*"v\([0-9.]*\)".*/\1/'` 假设 GitHub API 返回的 `tag_name` 带有 `v` 前缀（如 `"v1.26.0"`），但 istio/istio 仓库实际返回的是不带 `v` 的纯数字版本号（如 `"tag_name": "1.30.2"`）。该 sed 表达式因找不到字面量 `v` 而不做任何替换，导致 `ISTIO_VERSION` 变量被赋值为整行 JSON 文本，后续下载 URL 拼接失败（404 Not Found）。已改用直接匹配 `"tag_name": "X.Y.Z"` 的正则提取版本号。

```bash
ISTIO_VERSION=$(curl -sL https://api.github.com/repos/istio/istio/releases/latest \
  | grep '"tag_name"' | sed -E 's/.*"tag_name": *"([0-9.]+)".*/\1/' | head -1 2>/dev/null || echo "1.26.0")

curl -L https://istio.io/downloadIstio | ISTIO_VERSION=${ISTIO_VERSION} TARGET_ARCH=x86_64 sh -

cd istio-${ISTIO_VERSION} 2>/dev/null || cd istio-*
export PATH="$PWD/bin:$PATH"
cd ~

istioctl version --remote=false
echo "istioctl 安装完成"
```

**预期输出**：打印 istioctl 版本，无报错。

### 2. 安装 Istio 控制面

```bash
istioctl install --set profile=demo -y

kubectl rollout status deployment/istiod -n istio-system --timeout=5m
echo "Istio 控制面已安装"

kubectl get pods -n istio-system
```

**预期输出**：`istiod`、`istio-ingressgateway` 等 Pod Running。

### 3. 创建并标记 istio-demo namespace

```bash
kubectl create namespace ${ISTIO_NS}
kubectl label namespace ${ISTIO_NS} istio-injection=enabled --overwrite

kubectl get namespace ${ISTIO_NS} --show-labels
```

**预期输出**：namespace 显示 `istio-injection=enabled` label。

### 4. 部署 Bookinfo 示例应用

```bash
ISTIO_DIR=$(ls -d ~/istio-* 2>/dev/null | head -1)

kubectl apply -n ${ISTIO_NS} -f \
  ${ISTIO_DIR}/samples/bookinfo/platform/kube/bookinfo.yaml

kubectl rollout status deployment/productpage-v1 -n ${ISTIO_NS} --timeout=5m
kubectl rollout status deployment/details-v1 -n ${ISTIO_NS} --timeout=3m
kubectl rollout status deployment/reviews-v1 -n ${ISTIO_NS} --timeout=3m

echo "=== 验证 sidecar 注入 ==="
kubectl get pods -n ${ISTIO_NS} -o jsonpath='{range .items[*]}{.metadata.name}: containers={.spec.containers[*].name} initContainers={.spec.initContainers[*].name}{"\n"}{end}'
```

**预期输出**：每个 Pod 都包含 `istio-proxy`。

> **已验证：** Istio 1.29+ 在支持 Kubernetes Native Sidecar（`initContainers` + `restartPolicy: Always`，K8s 1.28+ 特性）的集群上，默认把 `istio-proxy` 注入为 **native sidecar**，即出现在 `.spec.initContainers` 而非 `.spec.containers` 中。原验证命令只检查 `.spec.containers`，在 EKS 1.35（完整支持该特性）上会误判为"未注入"。已将验证命令同时打印 `containers` 和 `initContainers`，请确认 `istio-proxy` 出现在其中之一即可。

### 5. 创建 Ingress Gateway 暴露 Bookinfo

```bash
kubectl apply -n ${ISTIO_NS} -f \
  ${ISTIO_DIR}/samples/bookinfo/networking/bookinfo-gateway.yaml

echo "等待 Ingress Gateway LoadBalancer 地址..."
for i in $(seq 1 20); do
  INGRESS_IP=$(kubectl get svc istio-ingressgateway -n istio-system \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || \
    kubectl get svc istio-ingressgateway -n istio-system \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
  [ -n "${INGRESS_IP}" ] && { echo "Ingress 地址: ${INGRESS_IP}"; break; }
  echo "等待 LB 地址..."
  sleep 15
done

curl -s -o /dev/null -w "productpage HTTP: %{http_code}\n" \
  --max-time 10 http://${INGRESS_IP}/productpage
```

**预期输出**：`productpage HTTP: 200`

### 6. 金丝雀流量管理（VirtualService + DestinationRule）

```bash
kubectl apply -n ${ISTIO_NS} -f \
  ${ISTIO_DIR}/samples/bookinfo/networking/destination-rule-all.yaml

echo "=== 第一步：所有流量路由到 reviews-v1（无评星）==="
kubectl apply -n ${ISTIO_NS} -f - <<'EOF'
apiVersion: networking.istio.io/v1alpha3
kind: VirtualService
metadata:
  name: reviews
spec:
  hosts:
  - reviews
  http:
  - route:
    - destination:
        host: reviews
        subset: v1
      weight: 100
EOF

echo "=== 第二步：灰度 50% 到 reviews-v3（红色评星）==="
kubectl apply -n ${ISTIO_NS} -f - <<'EOF'
apiVersion: networking.istio.io/v1alpha3
kind: VirtualService
metadata:
  name: reviews
spec:
  hosts:
  - reviews
  http:
  - route:
    - destination:
        host: reviews
        subset: v1
      weight: 50
    - destination:
        host: reviews
        subset: v3
      weight: 50
EOF

echo "访问 http://${INGRESS_IP}/productpage 多次，观察评星颜色变化（v1 无，v3 红色）"
kubectl get virtualservice -n ${ISTIO_NS}
```

**预期输出**：VirtualService 生效，多次访问页面评星版本按比例变化。

### 7. 启用 mTLS（PeerAuthentication STRICT）

```bash
kubectl apply -n ${ISTIO_NS} -f - <<'EOF'
apiVersion: security.istio.io/v1beta1
kind: PeerAuthentication
metadata:
  name: default
spec:
  mtls:
    mode: STRICT
EOF

echo "mTLS STRICT 已启用，服务间流量自动加密"

echo "=== 验证 mTLS 生效（Bookinfo 仍可正常访问）==="
curl -s -o /dev/null -w "mTLS 后 productpage HTTP: %{http_code}\n" \
  --max-time 10 http://${INGRESS_IP}/productpage
```

**预期输出**：`mTLS 后 productpage HTTP: 200`（mesh 内服务使用 mTLS，入口仍 HTTP）

### 8. AuthorizationPolicy 服务间授权

```bash
echo "=== 启用 deny-all（默认拒绝所有服务间流量）==="
kubectl apply -n ${ISTIO_NS} -f - <<'EOF'
apiVersion: security.istio.io/v1beta1
kind: AuthorizationPolicy
metadata:
  name: deny-all
spec:
  {}
EOF

echo "等待策略生效..."
sleep 5

echo "=== 此时 productpage 访问应返回 403（内部服务被拒绝）==="
curl -s -o /dev/null -w "deny-all 后 HTTP: %{http_code}\n" \
  --max-time 10 http://${INGRESS_IP}/productpage

echo "=== 放开 productpage 调用 details 和 reviews ==="
kubectl apply -n ${ISTIO_NS} -f - <<'EOF'
apiVersion: security.istio.io/v1beta1
kind: AuthorizationPolicy
metadata:
  name: allow-productpage
spec:
  selector:
    matchLabels:
      app: productpage
  action: ALLOW
  rules:
  - from:
    - source:
        principals: ["cluster.local/ns/istio-system/sa/istio-ingressgateway-service-account"]
---
apiVersion: security.istio.io/v1beta1
kind: AuthorizationPolicy
metadata:
  name: allow-details
spec:
  selector:
    matchLabels:
      app: details
  action: ALLOW
  rules:
  - from:
    - source:
        principals: ["cluster.local/ns/istio-demo/sa/bookinfo-productpage"]
---
apiVersion: security.istio.io/v1beta1
kind: AuthorizationPolicy
metadata:
  name: allow-reviews
spec:
  selector:
    matchLabels:
      app: reviews
  action: ALLOW
  rules:
  - from:
    - source:
        principals: ["cluster.local/ns/istio-demo/sa/bookinfo-productpage"]
EOF

sleep 10
curl -s -o /dev/null -w "AuthorizationPolicy 后 HTTP: %{http_code}\n" \
  --max-time 10 http://${INGRESS_IP}/productpage
```

**预期输出**：`AuthorizationPolicy 后 HTTP: 200`

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
| 1 | `kubectl get pods -n istio-system --no-headers \| grep Running \| grep istiod \| wc -l \| tr -d ' '` | `1` |
| 2 | `kubectl get namespace istio-demo -o jsonpath='{.metadata.labels.istio-injection}'` | `enabled` |
| 3 | `kubectl get pods -n istio-demo -o jsonpath='{.items[0].spec.containers[*].name} {.items[0].spec.initContainers[*].name}' \| tr ' ' '\n' \| grep -c istio-proxy`（EKS 1.35 支持 Native Sidecar，`istio-proxy` 注入到 `initContainers`，需一并检查） | `1` |
| 4 | `kubectl get virtualservice reviews -n istio-demo -o jsonpath='{.spec.http[0].route[0].destination.host}' 2>/dev/null` | `reviews` |

---

## 实验总结

本实验完成了「Istio 服务网格」的全部操作，从资源创建到功能验证形成了完整闭环。通过动手实践，你已掌握了相关组件在生产环境中的核心配置方法和最佳实践。至此完成 EKS Advance 全部进阶实验。

---

## 清理

```bash
kubectl delete namespace ${ISTIO_NS} 2>/dev/null || true

istioctl uninstall --purge -y 2>/dev/null || true
kubectl delete namespace istio-system 2>/dev/null || true

echo "等待 Istio Ingress Gateway LoadBalancer 释放（约 30 秒）..."
sleep 30

echo "清理完成"
```
