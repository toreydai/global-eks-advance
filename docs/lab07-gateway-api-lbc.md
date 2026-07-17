# Lab07 — Gateway API 和 AWS Load Balancer Controller 入口进阶

## 实验简介

本实验将完成「Gateway API 与 LB Controller」的全部操作，属于 EKS 进阶课程，面向有基础集群操作经验的学员。

**实验目标：**
- 掌握 Gateway API 与 LB Controller 的核心配置与操作流程
- 理解相关组件的架构原理和最佳实践
- 能够独立完成从部署到验证的完整闭环

**实验流程：**
1. 安装或升级 AWS Load Balancer Controller
2. 安装 Gateway API CRD
3. 创建测试 namespace 和后端服务
4. 创建 LoadBalancerConfiguration、GatewayClass、Gateway
5. 创建 HTTPRoute 实现路径路由

**预计 AI 执行时长：** 10-12 分钟


## 前提条件

- **工具**：AWS CLI v2、eksctl、kubectl v1.35、Helm v3
- **权限**：AdministratorAccess（含 EKS、EC2、IAM、ELB 创建权限）
- **前提**：EKS 集群可用，eks-pod-identity-agent 已安装
- **初始化**：

```bash
export AWS_REGION=us-east-1
export AWS_DEFAULT_REGION=us-east-1
export CLUSTER_NAME=demo
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export GATEWAY_NS=gateway-demo
```

---

## 步骤

### 1. 安装或升级 AWS Load Balancer Controller

> **注意：** `enableGatewayAPI=true` 在当前 chart（v3.4.1）中不是有效的 values key，设置了也不生效。正确方式是 `controllerConfig.featureGates.ALBGatewayAPI=true` 和 `NLBGatewayAPI=true`（下方命令已采用）。
>
> **注意：** 升级已有 LBC 时不要用 `helm upgrade --reuse-values`——新版 chart 新增的顶层 key（如 `certManagement`）在旧 release 的已存 values 里不存在，会导致模板报错。改为显式传入全部关键 values（下方命令已采用）。

```bash
LBC_PRESENT=$(kubectl get deployment aws-load-balancer-controller \
  -n kube-system --no-headers 2>/dev/null | wc -l | tr -d ' ')

if [ "${LBC_PRESENT}" = "0" ]; then
  echo "=== 安装 AWS Load Balancer Controller ==="
  
  cat > /tmp/lbc-trust.json << EOF
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"pods.eks.amazonaws.com"},"Action":["sts:AssumeRole","sts:TagSession"]}]}
EOF

  curl -sSLo /tmp/lbc-policy.json \
    https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json

  LBC_POLICY_ARN=$(aws iam create-policy \
    --policy-name AWSLoadBalancerControllerIAMPolicy \
    --policy-document file:///tmp/lbc-policy.json \
    --query Policy.Arn --output text 2>/dev/null || \
    aws iam list-policies \
      --query 'Policies[?PolicyName==`AWSLoadBalancerControllerIAMPolicy`].Arn' \
      --output text)

  LBC_ROLE_ARN=$(aws iam create-role \
    --role-name AmazonEKSLoadBalancerControllerRole \
    --assume-role-policy-document file:///tmp/lbc-trust.json \
    --query Role.Arn --output text 2>/dev/null || \
    aws iam get-role --role-name AmazonEKSLoadBalancerControllerRole \
      --query Role.Arn --output text)

  aws iam attach-role-policy \
    --role-name AmazonEKSLoadBalancerControllerRole \
    --policy-arn ${LBC_POLICY_ARN} 2>/dev/null || true

  kubectl create serviceaccount aws-load-balancer-controller \
    -n kube-system 2>/dev/null || true

  aws eks create-pod-identity-association \
    --cluster-name ${CLUSTER_NAME} \
    --namespace kube-system \
    --service-account aws-load-balancer-controller \
    --role-arn ${LBC_ROLE_ARN} \
    --region ${AWS_REGION} 2>/dev/null || true

  helm repo add eks https://aws.github.io/eks-charts
  helm repo update
  
  helm upgrade --install aws-load-balancer-controller \
    eks/aws-load-balancer-controller \
    --namespace kube-system \
    --set clusterName=${CLUSTER_NAME} \
    --set serviceAccount.create=false \
    --set serviceAccount.name=aws-load-balancer-controller \
    --set controllerConfig.featureGates.ALBGatewayAPI=true \
    --set controllerConfig.featureGates.NLBGatewayAPI=true \
    --wait

  echo "LBC 安装完成"
else
  echo "=== LBC 已存在，升级以启用 Gateway API ==="
  VPC_ID_CURRENT=$(aws eks describe-cluster --name ${CLUSTER_NAME} \
    --region ${AWS_REGION} --query 'cluster.resourcesVpcConfig.vpcId' --output text)
  # 注意：不要用 --reuse-values，新版 chart（实测 3.4.1）新增的顶层 key（如 certManagement）
  # 在旧 release 的已存 values 里不存在时，--reuse-values 不会用新 chart 默认值补齐，
  # 会导致模板报 "nil pointer evaluating interface {}.defaultPCAARN"。改为显式传入全部关键 values。
  helm upgrade aws-load-balancer-controller \
    eks/aws-load-balancer-controller \
    --namespace kube-system \
    --set clusterName=${CLUSTER_NAME} \
    --set region=${AWS_REGION} \
    --set vpcId=${VPC_ID_CURRENT} \
    --set serviceAccount.create=false \
    --set serviceAccount.name=aws-load-balancer-controller \
    --set controllerConfig.featureGates.ALBGatewayAPI=true \
    --set controllerConfig.featureGates.NLBGatewayAPI=true \
    --wait 2>/dev/null || echo "已是最新版本"
fi

kubectl rollout status deployment/aws-load-balancer-controller -n kube-system --timeout=5m
echo "AWS Load Balancer Controller 就绪"
```

**预期输出**：打印"AWS Load Balancer Controller 就绪"

### 2. 安装 Gateway API CRD

```bash
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.0/standard-install.yaml

echo "等待 CRD 注册..."
sleep 5

kubectl get crd | grep gateway.networking.k8s.io
```

**预期输出**：显示 `gatewayclasses`、`gateways`、`httproutes` 等 CRD。

### 3. 创建测试 namespace 和后端服务

```bash
kubectl create namespace ${GATEWAY_NS}

kubectl apply -n ${GATEWAY_NS} -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: app-v1
spec:
  replicas: 2
  selector:
    matchLabels:
      app: app-v1
  template:
    metadata:
      labels:
        app: app-v1
    spec:
      containers:
      - name: nginx
        image: public.ecr.aws/nginx/nginx:latest
        ports:
        - containerPort: 80
        resources:
          requests:
            cpu: 50m
            memory: 64Mi
---
apiVersion: v1
kind: Service
metadata:
  name: app-v1
spec:
  type: NodePort
  selector:
    app: app-v1
  ports:
  - port: 80
    targetPort: 80
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: app-v2
spec:
  replicas: 2
  selector:
    matchLabels:
      app: app-v2
  template:
    metadata:
      labels:
        app: app-v2
    spec:
      containers:
      - name: httpd
        image: public.ecr.aws/docker/library/httpd:alpine
        ports:
        - containerPort: 80
        resources:
          requests:
            cpu: 50m
            memory: 64Mi
---
apiVersion: v1
kind: Service
metadata:
  name: app-v2
spec:
  type: NodePort
  selector:
    app: app-v2
  ports:
  - port: 80
    targetPort: 80
EOF

kubectl rollout status deployment/app-v1 -n ${GATEWAY_NS} --timeout=3m
kubectl rollout status deployment/app-v2 -n ${GATEWAY_NS} --timeout=3m
echo "测试服务已部署"
```

**预期输出**：打印"测试服务已部署"

### 4. 创建 LoadBalancerConfiguration、GatewayClass、Gateway

> **注意：** `LoadBalancerConfiguration` 的 CRD 里没有 `spec.vpcId` 字段，写了会被拒绝（`unknown field`）。VPC 由 LBC 部署时的 `--aws-vpc-id` 决定，无需也不能在这里重复指定（下方已去掉该字段，`VPC_ID` 变量仅用于日志展示）。

```bash
VPC_ID=$(aws eks describe-cluster --name ${CLUSTER_NAME} \
  --region ${AWS_REGION} --query 'cluster.resourcesVpcConfig.vpcId' --output text)
echo "集群 VPC（由 LBC 的 --aws-vpc-id 自动使用，无需写入 LoadBalancerConfiguration）: ${VPC_ID}"

kubectl apply -n ${GATEWAY_NS} -f - <<EOF
apiVersion: gateway.k8s.aws/v1beta1
kind: LoadBalancerConfiguration
metadata:
  name: alb-config
spec:
  scheme: internet-facing
  ipAddressType: ipv4
EOF
```

> **注意（影响 ALB scheme）：** 用 `metadata.annotations["gateway.k8s.aws/load-balancer-configuration"]` 关联 `Gateway` 和 `LoadBalancerConfiguration` 对当前版本 LBC（v3.4.1）无效，ALB 会恒为默认的 `internal`。正确方式是用 `spec.infrastructure.parametersRef` 绑定（下方已采用）。由于 ALB 的 `Scheme` 创建后不可变更，若已用注解方式建出 `internal` 的 ALB，必须删除 `Gateway` 后用 `infrastructure.parametersRef` 重新创建才能得到 `internet-facing`。

```bash

kubectl apply -f - <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: alb
spec:
  controllerName: gateway.k8s.aws/alb
EOF

kubectl apply -n ${GATEWAY_NS} -f - <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: alb-gateway
spec:
  gatewayClassName: alb
  infrastructure:
    parametersRef:
      group: gateway.k8s.aws
      kind: LoadBalancerConfiguration
      name: alb-config
  listeners:
  - name: http
    protocol: HTTP
    port: 80
EOF

echo "等待 ALB 创建（约 2-3 分钟）..."
for i in $(seq 1 20); do
  ADDR=$(kubectl get gateway alb-gateway -n ${GATEWAY_NS} \
    -o jsonpath='{.status.addresses[0].value}' 2>/dev/null)
  [ -n "${ADDR}" ] && { echo "ALB 地址: ${ADDR}"; break; }
  echo "等待 ALB 地址..."
  sleep 15
done
```

**预期输出**：Gateway 获取到 ALB DNS 地址。

### 5. 创建 HTTPRoute 实现路径路由

```bash
kubectl apply -n ${GATEWAY_NS} -f - <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: app-routes
spec:
  parentRefs:
  - name: alb-gateway
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /v1
    backendRefs:
    - name: app-v1
      port: 80
  - matches:
    - path:
        type: PathPrefix
        value: /v2
    backendRefs:
    - name: app-v2
      port: 80
  - backendRefs:
    - name: app-v1
      port: 80
EOF

sleep 10
ALB_DNS=$(kubectl get gateway alb-gateway -n ${GATEWAY_NS} \
  -o jsonpath='{.status.addresses[0].value}')
echo "=== 测试路由（按状态码） ==="
curl -s -o /dev/null -w "/ → %{http_code}\n" --max-time 10 http://${ALB_DNS}/
curl -s -o /dev/null -w "/v1 → %{http_code}\n" --max-time 10 http://${ALB_DNS}/v1/
echo "=== 测试路由（按后端 Server 头，验证路径确实分流到不同后端） ==="
curl -s -o /dev/null -D - --max-time 10 http://${ALB_DNS}/v1/ | grep -i '^Server:'
curl -s -o /dev/null -D - --max-time 10 http://${ALB_DNS}/v2/ | grep -i '^Server:'
```

> **说明：** 本实验的 `HTTPRoute` 只按 `PathPrefix` 转发、不做 `URLRewrite` 剥离前缀，而 `app-v1`/`app-v2` 镜像本身没有 `/v1`、`/v2` 这两个路径，所以路由正确生效时 `/v1/`、`/v2/` 反而应该返回 404（只有 `/` 返回 200），不代表配置错误。用响应头 `Server` 区分后端更可靠：`/v1/` 应为 `nginx`，`/v2/` 应为 `Apache`。如需 `/v1`、`/v2` 也返回 200，可在对应 rule 加 `URLRewrite` filter 剥离前缀。

**预期输出**：`/` 返回 `200`；`/v1`、`/v2` 返回 `404` 但 `Server` 头分别显示 `nginx` 与 `Apache`（证明路径路由生效）。

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
| 1 | `kubectl get crd gatewayclasses.gateway.networking.k8s.io -o jsonpath='{.metadata.name}' 2>/dev/null` | `gatewayclasses.gateway.networking.k8s.io` |
| 2 | `kubectl get gatewayclass alb -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}'` | `True` |
| 3 | `kubectl get gateway alb-gateway -n gateway-demo -o jsonpath='{.status.addresses[0].value}' 2>/dev/null \| grep -c 'amazonaws.com\|elb.amazonaws.com'` | `1` |
| 4 | `kubectl get httproute app-routes -n gateway-demo -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}' 2>/dev/null` | `True` |

---

## 实验总结

本实验完成了「Gateway API 与 LB Controller」的全部操作，从资源创建到功能验证形成了完整闭环。通过动手实践，你已掌握了相关组件在生产环境中的核心配置方法和最佳实践。Lab08 将学习 CodePipeline CI/CD。

---

## 清理

```bash
kubectl delete httproute app-routes -n ${GATEWAY_NS} 2>/dev/null || true
kubectl delete gateway alb-gateway -n ${GATEWAY_NS} 2>/dev/null || true
kubectl delete gatewayclass alb 2>/dev/null || true
kubectl delete loadbalancerconfiguration alb-config -n ${GATEWAY_NS} 2>/dev/null || true
kubectl delete namespace ${GATEWAY_NS} 2>/dev/null || true

echo "等待 ALB 释放（约 30 秒）..."
sleep 30

echo "清理完成"
```
