# Lab05 — GenAI 推理服务（GPU + vLLM）

## 实验简介

本实验将完成「GenAI GPU 推理（vLLM）」的全部操作，属于 EKS 进阶课程，面向有基础集群操作经验的学员。

**实验目标：**
- 掌握 GenAI GPU 推理（vLLM） 的核心配置与操作流程
- 理解相关组件的架构原理和最佳实践
- 能够独立完成从部署到验证的完整闭环

**实验流程：**
1. 检查 GPU 配额
2. 创建 GPU Managed Node Group
3. 安装 NVIDIA Device Plugin
4. 创建 S3 模型桶和 Pod Identity
5. 部署 vLLM 推理服务
6. 测试推理 API
7. 部署 DCGM Exporter 监控 GPU

**预计 AI 执行时长：** 15-20 分钟


## 前提条件

- **工具**：AWS CLI v2、eksctl、kubectl v1.35、Helm v3
- **权限**：AdministratorAccess（含 EKS、EC2、IAM、ECR、S3、CloudWatch、Service Quotas）
- **前提**：EKS 集群可用，**g5/g6 GPU 实例配额已申请**，Bedrock 可选
- **成本警告**：GPU 实例费用较高，演示结束后立即删除节点组
- **初始化**：

```bash
export AWS_REGION=us-east-1
export AWS_DEFAULT_REGION=us-east-1
export CLUSTER_NAME=demo
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export GENAI_NS=genai
```

---

## 步骤

### 1. 检查 GPU 配额

```bash
aws service-quotas get-service-quota \
  --service-code ec2 \
  --quota-code L-DB2E81BA \
  --region ${AWS_REGION} \
  --query 'Quota.Value' \
  --output text 2>/dev/null || \
echo "请在 Service Quotas 控制台确认 g5.xlarge 配额 > 0"
```

**预期输出**：大于 0 的数字，表示有 GPU 配额。

> ⚠️ 若配额为 0，需在 Service Quotas 控制台申请。申请后通常 1-2 个工作日生效。

### 2. 创建 GPU Managed Node Group

```bash
eksctl create nodegroup \
  --cluster ${CLUSTER_NAME} \
  --region ${AWS_REGION} \
  --name gpu-ng \
  --node-type g5.xlarge \
  --nodes 1 \
  --nodes-min 0 \
  --nodes-max 2 \
  --managed \
  --node-ami-family AmazonLinux2023 \
  --node-labels "workload=gpu"

echo "GPU 节点组已创建，等待节点 Ready..."
kubectl wait --for=condition=Ready node \
  -l eks.amazonaws.com/nodegroup=gpu-ng \
  --timeout=10m

kubectl get nodes -l workload=gpu
```

**预期输出**：GPU 节点 Ready，`WORKLOAD` 列显示 `gpu`。

### 3. 安装 NVIDIA Device Plugin

> **已验证：** (1) 使用 `--node-ami-family AmazonLinux2023` 创建 g5/g6 等 GPU 托管节点组时，eksctl 会自动识别出 GPU 实例类型并切换为 EKS 加速版 AMI（`AL2023_x86_64_NVIDIA`），**并自动安装 `kube-system/nvidia-device-plugin-daemonset`**（除非显式加 `--install-nvidia-plugin=false`）。因此本步骤的 `kubectl apply` 实际是在给一个已存在的 DaemonSet 打补丁，而非首次创建，这是预期行为，不影响后续操作。
> (2) **实测复现一个会导致命令挂起超时的真实问题**：NVIDIA 官方 static 清单（`nvidia-device-plugin.yml`）不带任何 `nodeSelector`，会被调度到集群里全部节点（包括非 GPU 节点）。在非 GPU 节点上容器因找不到 `/dev/nvidia*` 设备而进入 `CrashLoopBackOff`，导致 `kubectl rollout status` 因为 `numberUnavailable` 永远大于 0 而卡住直到超时（5 分钟），且不会自愈。已改为对该 DaemonSet 打 `nodeSelector: nvidia.com/gpu.present: "true"`，使其只调度到 GPU 节点，问题解决、`rollout status` 秒级通过。集群节点数越多、非 GPU 节点占比越高，此问题越明显。

```bash
kubectl apply -f https://raw.githubusercontent.com/NVIDIA/k8s-device-plugin/v0.19.1/deployments/static/nvidia-device-plugin.yml

# 关键修复：限定只调度到 GPU 节点，避免在非 GPU 节点上 CrashLoopBackOff 导致 rollout status 挂起
kubectl patch daemonset nvidia-device-plugin-daemonset -n kube-system --type='json' \
  -p='[{"op":"add","path":"/spec/template/spec/nodeSelector","value":{"nvidia.com/gpu.present":"true"}}]'

kubectl rollout status daemonset/nvidia-device-plugin-daemonset \
  -n kube-system --timeout=5m

echo "NVIDIA Device Plugin 已安装"

echo "=== GPU 节点资源 ==="
GPU_NODE=$(kubectl get nodes -l workload=gpu -o jsonpath='{.items[0].metadata.name}')
kubectl describe node ${GPU_NODE} | grep -A 5 "nvidia.com/gpu"
```

**预期输出**：节点 `nvidia.com/gpu: 1` 可分配。

### 4. 创建 S3 模型桶和 Pod Identity

```bash
MODEL_BUCKET="eks-genai-models-${ACCOUNT_ID}"
aws s3 mb s3://${MODEL_BUCKET} --region ${AWS_REGION}

kubectl create namespace ${GENAI_NS}
kubectl create serviceaccount vllm-sa -n ${GENAI_NS}

cat > /tmp/genai-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": ["s3:GetObject", "s3:ListBucket"],
    "Resource": [
      "arn:aws:s3:::${MODEL_BUCKET}",
      "arn:aws:s3:::${MODEL_BUCKET}/*"
    ]
  }]
}
EOF

GENAI_POLICY_ARN=$(aws iam create-policy \
  --policy-name GenAI-S3-Policy \
  --policy-document file:///tmp/genai-policy.json \
  --query Policy.Arn --output text)

cat > /tmp/pod-trust.json << EOF
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"pods.eks.amazonaws.com"},"Action":["sts:AssumeRole","sts:TagSession"]}]}
EOF

GENAI_ROLE_ARN=$(aws iam create-role \
  --role-name GenAI-vLLM-Role \
  --assume-role-policy-document file:///tmp/pod-trust.json \
  --query Role.Arn --output text)

aws iam attach-role-policy \
  --role-name GenAI-vLLM-Role \
  --policy-arn ${GENAI_POLICY_ARN}

aws eks create-pod-identity-association \
  --cluster-name ${CLUSTER_NAME} \
  --namespace ${GENAI_NS} \
  --service-account vllm-sa \
  --role-arn ${GENAI_ROLE_ARN} \
  --region ${AWS_REGION}

echo "S3 和 Pod Identity 已配置"
```

**预期输出**：打印"S3 和 Pod Identity 已配置"

### 5. 部署 vLLM 推理服务

> **注意：** Service 名字若与应用自身读取的环境变量同名（本例 `vllm`），K8s 自动注入的 `VLLM_PORT=tcp://...` 会和 vLLM 期望的纯整数端口冲突，导致 `ValueError: VLLM_PORT ... appears to be a URI` 崩溃。需在 Pod spec 加 `enableServiceLinks: false` 关闭该自动注入（Ray、Triton 等同类应用也有此坑）。

```bash
kubectl apply -n ${GENAI_NS} -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: vllm
spec:
  replicas: 1
  selector:
    matchLabels:
      app: vllm
  template:
    metadata:
      labels:
        app: vllm
    spec:
      serviceAccountName: vllm-sa
      enableServiceLinks: false
      nodeSelector:
        workload: gpu
      tolerations:
      - key: "nvidia.com/gpu"
        operator: Exists
        effect: NoSchedule
      containers:
      - name: vllm
        image: vllm/vllm-openai:latest
        args:
        - "--model"
        - "facebook/opt-125m"
        - "--port"
        - "8000"
        - "--max-model-len"
        - "512"
        ports:
        - containerPort: 8000
        resources:
          requests:
            nvidia.com/gpu: "1"
            memory: 8Gi
          limits:
            nvidia.com/gpu: "1"
            memory: 16Gi
        readinessProbe:
          httpGet:
            path: /health
            port: 8000
          initialDelaySeconds: 120
          periodSeconds: 30
          timeoutSeconds: 10
---
apiVersion: v1
kind: Service
metadata:
  name: vllm
spec:
  selector:
    app: vllm
  ports:
  - port: 8000
    targetPort: 8000
EOF

echo "等待 vLLM Pod Ready（首次下载模型约 3-5 分钟）..."
kubectl rollout status deployment/vllm -n ${GENAI_NS} --timeout=15m
echo "vLLM 已部署"
```

**预期输出**：打印"vLLM 已部署"

### 6. 测试推理 API

```bash
kubectl exec -n ${GENAI_NS} \
  $(kubectl get pods -n ${GENAI_NS} -l app=vllm -o jsonpath='{.items[0].metadata.name}') -- \
  curl -s http://localhost:8000/v1/models | python3 -m json.tool 2>/dev/null || \
  kubectl exec -n ${GENAI_NS} \
    $(kubectl get pods -n ${GENAI_NS} -l app=vllm -o jsonpath='{.items[0].metadata.name}') -- \
    wget -qO- http://localhost:8000/v1/models
```

**预期输出**：JSON 格式的模型列表，包含 `facebook/opt-125m`。

### 7. 部署 DCGM Exporter 监控 GPU

```bash
kubectl apply -n ${GENAI_NS} -f - <<'EOF'
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: dcgm-exporter
spec:
  selector:
    matchLabels:
      app: dcgm-exporter
  template:
    metadata:
      labels:
        app: dcgm-exporter
    spec:
      nodeSelector:
        workload: gpu
      containers:
      - name: exporter
        image: nvcr.io/nvidia/k8s/dcgm-exporter:4.2.3-4.1.1-ubuntu22.04
        ports:
        - containerPort: 9400
        securityContext:
          privileged: true
        resources:
          requests:
            cpu: 100m
            memory: 128Mi
EOF

echo "DCGM Exporter 已部署"
kubectl get pods -n ${GENAI_NS}
```

**预期输出**：打印"DCGM Exporter 已部署"

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
| 1 | `kubectl get nodes -l workload=gpu --no-headers \| grep Ready \| wc -l \| tr -d ' '` | `1` |
| 2 | `kubectl get daemonset nvidia-device-plugin-daemonset -n kube-system -o jsonpath='{.status.numberReady}'` | `1` |
| 3 | `kubectl get pods -n genai --no-headers \| grep Running \| grep vllm \| wc -l \| tr -d ' '` | `1` |
| 4 | `aws eks list-pod-identity-associations --cluster-name demo --namespace genai --service-account vllm-sa --region us-east-1 --query 'length(associations)' --output text` | `1` |

---

## 实验总结

本实验完成了「GenAI GPU 推理（vLLM）」的全部操作，从资源创建到功能验证形成了完整闭环。通过动手实践，你已掌握了相关组件在生产环境中的核心配置方法和最佳实践。Lab06 将学习 Spark on EKS 大数据处理。

---

## 清理

> **已验证：** `eksctl delete nodegroup` 对于托管节点组是异步操作（日志显示 `delete nodegroup "gpu-ng" [async]`），命令本身几十秒内返回，但底层 CloudFormation 栈删除、EC2 实例 `shutting-down → terminated` 通常还需要额外 3-5 分钟才真正完成，GPU 实例在这段时间内仍在计费。**务必轮询确认 EC2 实例已 `terminated` 且 CloudFormation 栈已不存在，再判定清理完成**，不要以 `eksctl delete nodegroup` 命令返回作为清理完成的依据：
> ```bash
> until aws cloudformation describe-stacks --stack-name eksctl-${CLUSTER_NAME}-nodegroup-gpu-ng --region ${AWS_REGION} \
>   --query 'Stacks[0].StackStatus' --output text 2>&1 | grep -q "does not exist"; do sleep 20; done
> aws ec2 describe-instances --filters "Name=tag:eks:nodegroup-name,Values=gpu-ng" \
>   --query 'Reservations[].Instances[].[InstanceId,State.Name]' --output text --region ${AWS_REGION}
> ```

```bash
kubectl delete namespace ${GENAI_NS} 2>/dev/null || true

for ASSOC in $(aws eks list-pod-identity-associations \
  --cluster-name ${CLUSTER_NAME} \
  --namespace ${GENAI_NS} \
  --service-account vllm-sa \
  --query 'associations[*].associationId' --output text 2>/dev/null); do
  aws eks delete-pod-identity-association \
    --cluster-name ${CLUSTER_NAME} \
    --association-id ${ASSOC} \
    --region ${AWS_REGION}
done

aws iam detach-role-policy \
  --role-name GenAI-vLLM-Role \
  --policy-arn ${GENAI_POLICY_ARN} 2>/dev/null || true
aws iam delete-role --role-name GenAI-vLLM-Role 2>/dev/null || true
aws iam delete-policy --policy-arn ${GENAI_POLICY_ARN} 2>/dev/null || true

aws s3 rm s3://${MODEL_BUCKET} --recursive 2>/dev/null || true
aws s3 rb s3://${MODEL_BUCKET} 2>/dev/null || true

eksctl delete nodegroup \
  --cluster ${CLUSTER_NAME} \
  --name gpu-ng \
  --region ${AWS_REGION}

echo "清理完成"
```
