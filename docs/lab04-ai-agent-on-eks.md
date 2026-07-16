# Lab04 — AI Agent on EKS

## 实验简介

本实验将完成「AI Agent on EKS」的全部操作，属于 EKS 进阶课程，面向有基础集群操作经验的学员。

**实验目标：**
- 掌握 AI Agent on EKS 的核心配置与操作流程
- 理解相关组件的架构原理和最佳实践
- 能够独立完成从部署到验证的完整闭环

**实验流程：**
1. 确认 Bedrock 模型可用
2. 创建 namespace 和 ServiceAccount
3. 创建 IAM Policy 和 Pod Identity Role
4. 创建 DynamoDB 会话表
5. 创建 Secrets Manager 示例凭证
6. 部署 AI Agent 服务
7. 验证 Pod Identity 和健康检查
8. 演示 v2 灰度发布

**预计 AI 执行时长：** 12-15 分钟


## 前提条件

- **工具**：AWS CLI v2、kubectl v1.35、Docker（可选，如需构建镜像）
- **权限**：AdministratorAccess（含 EKS、IAM、ECR、Bedrock、DynamoDB、Secrets Manager、CloudWatch Logs）
- **前提**：EKS 1.35 集群可用，eks-pod-identity-agent 已安装，Bedrock 模型已在 us-east-1 开通
- **初始化**：

```bash
export AWS_REGION=us-east-1
export AWS_DEFAULT_REGION=us-east-1
export CLUSTER_NAME=demo
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export AGENT_NS=agent-demo
```

---

## 步骤

### 1. 确认 Bedrock 模型可用

```bash
aws bedrock list-foundation-models \
  --region ${AWS_REGION} \
  --by-output-modality TEXT \
  --query 'modelSummaries[?modelId==`amazon.nova-lite-v1:0`].modelId' \
  --output text

echo "Bedrock 连接正常"
```

**预期输出**：打印 `amazon.nova-lite-v1:0`（或其他已开通模型 ID；`amazon.titan-text-lite-v1` 已被 AWS 标记 end-of-life，调用会返回 `ResourceNotFoundException`，请勿再使用该模型 ID）

### 2. 创建 namespace 和 ServiceAccount

```bash
kubectl create namespace ${AGENT_NS}
kubectl create serviceaccount agent-sa -n ${AGENT_NS}
echo "Namespace 和 ServiceAccount 已创建"
```

**预期输出**：打印"Namespace 和 ServiceAccount 已创建"

### 3. 创建 IAM Policy 和 Pod Identity Role

```bash
cat > /tmp/agent-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "bedrock:InvokeModel",
        "bedrock:InvokeModelWithResponseStream"
      ],
      "Resource": "arn:aws:bedrock:${AWS_REGION}::foundation-model/*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "dynamodb:GetItem",
        "dynamodb:PutItem",
        "dynamodb:UpdateItem",
        "dynamodb:Query"
      ],
      "Resource": "arn:aws:dynamodb:${AWS_REGION}:${ACCOUNT_ID}:table/agent-sessions"
    },
    {
      "Effect": "Allow",
      "Action": ["secretsmanager:GetSecretValue"],
      "Resource": "arn:aws:secretsmanager:${AWS_REGION}:${ACCOUNT_ID}:secret:agent-webhook-*"
    }
  ]
}
EOF

AGENT_POLICY_ARN=$(aws iam create-policy \
  --policy-name AgentOnEKS-Policy \
  --policy-document file:///tmp/agent-policy.json \
  --query Policy.Arn --output text)

cat > /tmp/pod-trust.json << EOF
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"pods.eks.amazonaws.com"},"Action":["sts:AssumeRole","sts:TagSession"]}]}
EOF

AGENT_ROLE_ARN=$(aws iam create-role \
  --role-name AgentOnEKS-Role \
  --assume-role-policy-document file:///tmp/pod-trust.json \
  --query Role.Arn --output text)

aws iam attach-role-policy \
  --role-name AgentOnEKS-Role \
  --policy-arn ${AGENT_POLICY_ARN}

aws eks create-pod-identity-association \
  --cluster-name ${CLUSTER_NAME} \
  --namespace ${AGENT_NS} \
  --service-account agent-sa \
  --role-arn ${AGENT_ROLE_ARN} \
  --region ${AWS_REGION}

echo "Pod Identity 已配置"
```

**预期输出**：打印"Pod Identity 已配置"

### 4. 创建 DynamoDB 会话表

```bash
aws dynamodb create-table \
  --table-name agent-sessions \
  --attribute-definitions AttributeName=session_id,AttributeType=S \
  --key-schema AttributeName=session_id,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region ${AWS_REGION}

aws dynamodb wait table-exists --table-name agent-sessions --region ${AWS_REGION}
echo "DynamoDB 表已创建"
```

**预期输出**：打印"DynamoDB 表已创建"

### 5. 创建 Secrets Manager 示例凭证

```bash
aws secretsmanager create-secret \
  --name agent-webhook-demo \
  --secret-string '{"webhook_url":"https://example.com/hook","api_key":"demo-key"}' \
  --region ${AWS_REGION}

echo "Secret 已创建（不打印完整值）"
```

**预期输出**：打印"Secret 已创建"（不打印 secret 内容）

### 6. 部署 AI Agent 服务

```bash
kubectl apply -n ${AGENT_NS} -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: agent
spec:
  replicas: 2
  selector:
    matchLabels:
      app: agent
  template:
    metadata:
      labels:
        app: agent
        version: v1
    spec:
      serviceAccountName: agent-sa
      containers:
      - name: agent
        image: public.ecr.aws/docker/library/python:3.12-alpine
        command: ["python3", "-c"]
        args:
        - |
          import http.server, json, os, time
          class H(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
              if self.path == '/health':
                self.send_response(200)
                self.end_headers()
                self.wfile.write(b'ok')
              elif self.path == '/identity':
                import urllib.request, os
                try:
                  with open('/var/run/secrets/pods.eks.amazonaws.com/serviceaccount/eks-pod-identity-token') as f:
                    tok = f.read().strip()
                  req = urllib.request.Request(
                    os.environ.get('AWS_CONTAINER_CREDENTIALS_FULL_URI', 'http://169.254.170.23/v1/credentials'),
                    headers={'Authorization': tok})
                  r = urllib.request.urlopen(req, timeout=2)
                  self.send_response(200)
                  self.end_headers()
                  self.wfile.write(b'Pod Identity OK')
                except Exception:
                  self.send_response(200)
                  self.end_headers()
                  self.wfile.write(b'Identity check done')
            def log_message(self, *args): pass
          http.server.HTTPServer(('', 8080), H).serve_forever()
        ports:
        - containerPort: 8080
        env:
        - name: AWS_REGION
          value: "${AWS_REGION}"
        - name: DYNAMODB_TABLE
          value: "agent-sessions"
        resources:
          requests:
            cpu: 100m
            memory: 128Mi
---
apiVersion: v1
kind: Service
metadata:
  name: agent
spec:
  selector:
    app: agent
  ports:
  - port: 80
    targetPort: 8080
EOF

kubectl rollout status deployment/agent -n ${AGENT_NS} --timeout=5m
echo "AI Agent 已部署（2 副本）"
```

**预期输出**：打印"AI Agent 已部署（2 副本）"

> **已验证：** 原示例代码里 `/identity` 探测的是经典 EC2 IMDS 地址 `169.254.169.254/latest/meta-data/iam/security-credentials/`，这与 EKS Pod Identity 无关——Pod Identity 通过环境变量 `AWS_CONTAINER_CREDENTIALS_FULL_URI`（实测指向 `169.254.170.23/v1/credentials`）+ 挂载的 token 文件 `/var/run/secrets/pods.eks.amazonaws.com/serviceaccount/eks-pod-identity-token` 提供临时凭证，走的是 EKS Pod Identity Agent 而非传统 IMDS，因此原代码无论 Pod Identity 是否配置成功，`/identity` 永远返回 `Identity check done`，不会返回 `Pod Identity OK`，无法达成实验预期输出。已将示例代码改为读取 token 文件并携带 `Authorization` 头请求 `AWS_CONTAINER_CREDENTIALS_FULL_URI`，实测能正确拿到临时凭证并返回 `Pod Identity OK`。

### 7. 验证 Pod Identity 和健康检查

```bash
AGENT_POD=$(kubectl get pods -n ${AGENT_NS} -l app=agent -o jsonpath='{.items[0].metadata.name}')

echo "=== Pod 运行状态 ==="
kubectl get pods -n ${AGENT_NS}

echo "=== 验证 Pod Identity（AWS Credentials 自动注入）==="
kubectl exec -n ${AGENT_NS} ${AGENT_POD} -- \
  wget -qO- http://127.0.0.1:8080/health

echo "=== 健康检查 ==="
kubectl exec -n ${AGENT_NS} ${AGENT_POD} -- \
  wget -qO- http://127.0.0.1:8080/identity
```

> **已验证：** 容器内 `/etc/hosts` 将 `localhost` 优先解析到 `::1`（IPv6），但示例代码里的 `http.server.HTTPServer(('', 8080), H)` 只绑定 IPv4（等价于 `0.0.0.0:8080`），未监听 IPv6，导致 `wget http://localhost:8080/...` 报 `Connection refused`。已将命令中的 `localhost` 改为 `127.0.0.1` 规避该问题（`ps`/`ss` 已确认进程正常监听 `0.0.0.0:8080`，只是 IPv6 环回不可达）。

**预期输出**：返回 `ok` 和 `Pod Identity OK`

### 8. 演示 v2 灰度发布

```bash
kubectl set image deployment/agent agent=public.ecr.aws/docker/library/python:3.12-slim \
  -n ${AGENT_NS} 2>/dev/null || \
kubectl rollout restart deployment/agent -n ${AGENT_NS}

kubectl rollout status deployment/agent -n ${AGENT_NS} --timeout=5m
kubectl get pods -n ${AGENT_NS}
echo "v2 发布完成"
```

**预期输出**：打印"v2 发布完成"，新 Pod 使用更新后的镜像。

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
| 1 | `aws dynamodb describe-table --table-name agent-sessions --region us-east-1 --query 'Table.TableStatus' --output text` | `ACTIVE` |
| 2 | `kubectl get pods -n agent-demo --no-headers \| grep Running \| wc -l \| tr -d ' '` | `2` |
| 3 | `aws eks list-pod-identity-associations --cluster-name demo --namespace agent-demo --service-account agent-sa --region us-east-1 --query 'length(associations)' --output text` | `1` |
| 4 | `kubectl get deployment agent -n agent-demo -o jsonpath='{.status.readyReplicas}'` | `2` |

---

## 实验总结

本实验完成了「AI Agent on EKS」的全部操作，从资源创建到功能验证形成了完整闭环。通过动手实践，你已掌握了相关组件在生产环境中的核心配置方法和最佳实践。Lab05 将学习 GPU 推理服务部署。

---

## 清理

```bash
kubectl delete namespace ${AGENT_NS} 2>/dev/null || true

for ASSOC in $(aws eks list-pod-identity-associations \
  --cluster-name ${CLUSTER_NAME} \
  --namespace ${AGENT_NS} \
  --service-account agent-sa \
  --query 'associations[*].associationId' --output text 2>/dev/null); do
  aws eks delete-pod-identity-association \
    --cluster-name ${CLUSTER_NAME} \
    --association-id ${ASSOC} \
    --region ${AWS_REGION}
done

aws iam detach-role-policy \
  --role-name AgentOnEKS-Role \
  --policy-arn ${AGENT_POLICY_ARN} 2>/dev/null || true
aws iam delete-role --role-name AgentOnEKS-Role 2>/dev/null || true
aws iam delete-policy --policy-arn ${AGENT_POLICY_ARN} 2>/dev/null || true

aws dynamodb delete-table --table-name agent-sessions --region ${AWS_REGION} 2>/dev/null || true
aws secretsmanager delete-secret --secret-id agent-webhook-demo --force-delete-without-recovery \
  --region ${AWS_REGION} 2>/dev/null || true

echo "清理完成"
```
