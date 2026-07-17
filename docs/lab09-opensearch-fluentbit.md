# Lab09 — OpenSearch 和 Fluent Bit 日志平台

## 实验简介

本实验将完成「OpenSearch 与 FluentBit 日志平台」的全部操作，属于 EKS 进阶课程，面向有基础集群操作经验的学员。

**实验目标：**
- 掌握 OpenSearch 与 FluentBit 日志平台 的核心配置与操作流程
- 理解相关组件的架构原理和最佳实践
- 能够独立完成从部署到验证的完整闭环

**实验流程：**
1. 创建 Fluent Bit Pod Identity IAM Policy 和 Role
2. 创建 OpenSearch Domain
3. 部署 Fluent Bit DaemonSet
4. 部署日志生成器应用
5. 验证 Fluent Bit 日志
6. 访问 OpenSearch Dashboards

**预计 AI 执行时长：** 10-12 分钟


## 前提条件

- **工具**：AWS CLI v2、kubectl v1.35、Helm v3
- **权限**：AdministratorAccess（含 EKS、IAM、OpenSearch、EC2、CloudWatch Logs）
- **前提**：EKS 集群可用，eks-pod-identity-agent 已安装
- **成本警告**：OpenSearch domain 持续计费，演示结束后立即删除
- **初始化**：

```bash
export AWS_REGION=us-east-1
export AWS_DEFAULT_REGION=us-east-1
export CLUSTER_NAME=demo
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export OS_DOMAIN=eks-logs-demo
export LOG_NS=logging
```

---

## 步骤

### 1. 创建 Fluent Bit Pod Identity IAM Policy 和 Role

```bash
cat > /tmp/fluentbit-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": [
      "es:ESHttpPost",
      "es:ESHttpPut",
      "es:ESHttpGet",
      "es:ESHttpHead"
    ],
    "Resource": "arn:aws:es:${AWS_REGION}:${ACCOUNT_ID}:domain/${OS_DOMAIN}/*"
  }]
}
EOF

FB_POLICY_ARN=$(aws iam create-policy \
  --policy-name FluentBit-OpenSearch-Policy \
  --policy-document file:///tmp/fluentbit-policy.json \
  --query Policy.Arn --output text)

cat > /tmp/pod-trust.json << EOF
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"pods.eks.amazonaws.com"},"Action":["sts:AssumeRole","sts:TagSession"]}]}
EOF

FB_ROLE_ARN=$(aws iam create-role \
  --role-name FluentBit-OpenSearch-Role \
  --assume-role-policy-document file:///tmp/pod-trust.json \
  --query Role.Arn --output text)

aws iam attach-role-policy \
  --role-name FluentBit-OpenSearch-Role \
  --policy-arn ${FB_POLICY_ARN}

kubectl create namespace ${LOG_NS}
kubectl create serviceaccount fluent-bit -n ${LOG_NS}

aws eks create-pod-identity-association \
  --cluster-name ${CLUSTER_NAME} \
  --namespace ${LOG_NS} \
  --service-account fluent-bit \
  --role-arn ${FB_ROLE_ARN} \
  --region ${AWS_REGION}

echo "Fluent Bit IAM 配置完成"
```

**预期输出**：打印"Fluent Bit IAM 配置完成"

### 2. 创建 OpenSearch Domain

```bash
cat > /tmp/os-access-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "AWS": "${FB_ROLE_ARN}"
      },
      "Action": "es:*",
      "Resource": "arn:aws:es:${AWS_REGION}:${ACCOUNT_ID}:domain/${OS_DOMAIN}/*"
    }
  ]
}
EOF

aws opensearch create-domain \
  --domain-name ${OS_DOMAIN} \
  --engine-version "OpenSearch_2.17" \
  --cluster-config "InstanceType=t3.small.search,InstanceCount=1" \
  --ebs-options "EBSEnabled=true,VolumeType=gp3,VolumeSize=20" \
  --access-policies file:///tmp/os-access-policy.json \
  --region ${AWS_REGION}

echo "OpenSearch domain 创建中，等待 ACTIVE（约 10-20 分钟）..."
until [ "$(aws opensearch describe-domain --domain-name ${OS_DOMAIN} \
  --region ${AWS_REGION} \
  --query 'DomainStatus.Processing' --output text 2>/dev/null)" = "False" ]; do
  echo "等待 OpenSearch 准备就绪..."
  sleep 60
done

OS_ENDPOINT=$(aws opensearch describe-domain \
  --domain-name ${OS_DOMAIN} \
  --region ${AWS_REGION} \
  --query 'DomainStatus.Endpoints.vpc' \
  --output text 2>/dev/null || \
  aws opensearch describe-domain \
    --domain-name ${OS_DOMAIN} \
    --region ${AWS_REGION} \
    --query 'DomainStatus.Endpoint' \
    --output text)

echo "OpenSearch Endpoint: ${OS_ENDPOINT}"
```

**预期输出**：OpenSearch Endpoint 地址。

### 3. 部署 Fluent Bit DaemonSet

```bash
helm repo add fluent https://fluent.github.io/helm-charts
helm repo update

helm upgrade --install fluent-bit fluent/fluent-bit \
  --namespace ${LOG_NS} \
  --set serviceAccount.create=false \
  --set serviceAccount.name=fluent-bit \
  --set config.outputs="\
[OUTPUT]\n\
    Name  es\n\
    Match kubernetes.*\n\
    Host  ${OS_ENDPOINT}\n\
    Port  443\n\
    TLS   On\n\
    AWS_Auth On\n\
    AWS_Region ${AWS_REGION}\n\
    Index eks-logs\n\
    Logstash_Format On\n\
    Logstash_Prefix eks\n\
    Replace_Dots On" \
  --set config.filters="\
[FILTER]\n\
    Name kubernetes\n\
    Match kube.*\n\
    Merge_Log On\n\
    Keep_Log Off" \
  --wait \
  --timeout 5m

kubectl rollout status daemonset/fluent-bit -n ${LOG_NS} --timeout=5m
echo "Fluent Bit 已部署"
```

**预期输出**：打印"Fluent Bit 已部署"

### 4. 部署日志生成器应用

```bash
kubectl create deployment log-generator \
  --image=public.ecr.aws/docker/library/busybox:latest \
  -- sh -c 'i=0; while true; do echo "[$(date)] EKS log line $i from lab09"; i=$((i+1)); sleep 2; done'

kubectl rollout status deployment/log-generator --timeout=3m
echo "日志生成器运行中"

echo "等待 Fluent Bit 收集并发送日志（约 60 秒）..."
sleep 60
```

**预期输出**：打印"日志生成器运行中"

### 5. 验证 Fluent Bit 日志

```bash
echo "=== Fluent Bit DaemonSet 状态 ==="
kubectl get pods -n ${LOG_NS}

echo "=== 检查 Fluent Bit 日志（无持续 403/错误）==="
kubectl logs daemonset/fluent-bit -n ${LOG_NS} --tail=20 | grep -v "^$" | head -20
```

**预期输出**：Fluent Bit DaemonSet Pod Running；日志中无持续 403 或 connection error。

> **注意：** 带点的 Kubernetes 标签（如 `app.kubernetes.io/name`）会被 OpenSearch 动态 mapping 解析成嵌套 object，与不带点的普通标签（如 `app: log-generator`）写同一字段时会类型冲突——外层 HTTP 仍返回 200，但 `_bulk` 响应体里单条文档是 `400 mapper_parsing_exception`（需开 `Trace_Error On` 才能看到，仅看连接层日志会误判为网络问题）。需在 `[OUTPUT]` 加 `Replace_Dots On`，并删除已被污染 mapping 的索引后重建。

### 6. 访问 OpenSearch Dashboards

```bash
echo "=== OpenSearch Dashboards 地址 ==="
echo "https://${OS_ENDPOINT}/_dashboards"
echo ""
echo "请在浏览器中打开上述地址，创建 index pattern: eks-logs*"
echo "或通过 Kibana API 查看索引:"
echo "curl -XGET 'https://${OS_ENDPOINT}/_cat/indices?v' --aws-sigv4 aws:amz:${AWS_REGION}:es"
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
| 1 | `aws opensearch describe-domain --domain-name eks-logs-demo --region us-east-1 --query 'DomainStatus.Processing' --output text` | `False` |
| 2 | `kubectl get daemonset fluent-bit -n logging -o jsonpath='{.status.numberReady}'` | 大于 `0` |
| 3 | `aws eks list-pod-identity-associations --cluster-name demo --namespace logging --service-account fluent-bit --region us-east-1 --query 'length(associations)' --output text` | `1` |
| 4 | `kubectl get pods -n logging --no-headers \| grep Running \| wc -l \| tr -d ' '` | 大于 `0` |

---

## 实验总结

本实验完成了「OpenSearch 与 FluentBit 日志平台」的全部操作，从资源创建到功能验证形成了完整闭环。通过动手实践，你已掌握了相关组件在生产环境中的核心配置方法和最佳实践。Lab10 将学习 EKS 集群升级。

---

## 清理

```bash
kubectl delete deployment log-generator 2>/dev/null || true
helm uninstall fluent-bit -n ${LOG_NS} 2>/dev/null || true
kubectl delete namespace ${LOG_NS} 2>/dev/null || true

for ASSOC in $(aws eks list-pod-identity-associations \
  --cluster-name ${CLUSTER_NAME} \
  --namespace ${LOG_NS} \
  --service-account fluent-bit \
  --query 'associations[*].associationId' --output text 2>/dev/null); do
  aws eks delete-pod-identity-association \
    --cluster-name ${CLUSTER_NAME} \
    --association-id ${ASSOC} \
    --region ${AWS_REGION}
done

aws iam detach-role-policy \
  --role-name FluentBit-OpenSearch-Role \
  --policy-arn ${FB_POLICY_ARN} 2>/dev/null || true
aws iam delete-role --role-name FluentBit-OpenSearch-Role 2>/dev/null || true
aws iam delete-policy --policy-arn ${FB_POLICY_ARN} 2>/dev/null || true

aws opensearch delete-domain \
  --domain-name ${OS_DOMAIN} \
  --region ${AWS_REGION} 2>/dev/null || true

echo "清理完成（OpenSearch 删除约 5-10 分钟）"
```
