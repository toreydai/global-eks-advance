# Lab06 — Spark on EKS

## 实验简介

本实验将完成「Spark on EKS」的全部操作，属于 EKS 进阶课程，面向有基础集群操作经验的学员。

**实验目标：**
- 掌握 Spark on EKS 的核心配置与操作流程
- 理解相关组件的架构原理和最佳实践
- 能够独立完成从部署到验证的完整闭环

**实验流程：**
1. 创建 S3 数据桶并上传示例数据
2. 创建 Spark namespace 和 Pod Identity
3. 安装 Spark Operator
4. 提交 SparkApplication
5. 创建 EMR on EKS Virtual Cluster
6. 提交 EMR Spark 作业

**预计 AI 执行时长：** 12-15 分钟


## 前提条件

- **工具**：AWS CLI v2、eksctl、kubectl v1.35、Helm v3、jq
- **权限**：AdministratorAccess（含 EKS、IAM、S3、EMR Containers、CloudWatch Logs）
- **前提**：EKS 集群可用（`demo` 集群），Karpenter 可选（用于 Spot executor）
- **初始化**：

```bash
export AWS_REGION=us-east-1
export AWS_DEFAULT_REGION=us-east-1
export CLUSTER_NAME=demo
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export SPARK_BUCKET="eks-spark-data-${ACCOUNT_ID}"
```

---

## 步骤

### 1. 创建 S3 数据桶并上传示例数据

```bash
aws s3 mb s3://${SPARK_BUCKET} --region ${AWS_REGION}

cat > /tmp/sample.csv << 'EOF'
id,name,value
1,alpha,100
2,beta,200
3,gamma,150
4,delta,300
5,epsilon,250
EOF

cat > /tmp/wordcount.py << 'EOF'
from pyspark.sql import SparkSession

spark = SparkSession.builder.appName("WordCount").getOrCreate()
df = spark.read.csv("s3a://BUCKET_PLACEHOLDER/input/sample.csv", header=True, inferSchema=True)
df.groupBy("name").sum("value").write.mode("overwrite").csv("s3a://BUCKET_PLACEHOLDER/output/")
spark.stop()
EOF

sed -i "s/BUCKET_PLACEHOLDER/${SPARK_BUCKET}/g" /tmp/wordcount.py

aws s3 cp /tmp/sample.csv s3://${SPARK_BUCKET}/input/
aws s3 cp /tmp/wordcount.py s3://${SPARK_BUCKET}/scripts/

echo "数据和脚本已上传"
```

**预期输出**：打印"数据和脚本已上传"

### 2. 创建 Spark namespace 和 Pod Identity

```bash
kubectl create namespace spark

cat > /tmp/spark-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"],
    "Resource": [
      "arn:aws:s3:::${SPARK_BUCKET}",
      "arn:aws:s3:::${SPARK_BUCKET}/*"
    ]
  }]
}
EOF

SPARK_POLICY_ARN=$(aws iam create-policy \
  --policy-name SparkOnEKS-S3Policy \
  --policy-document file:///tmp/spark-policy.json \
  --query Policy.Arn --output text)

cat > /tmp/pod-trust.json << EOF
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"pods.eks.amazonaws.com"},"Action":["sts:AssumeRole","sts:TagSession"]}]}
EOF

SPARK_ROLE_ARN=$(aws iam create-role \
  --role-name SparkOnEKS-Role \
  --assume-role-policy-document file:///tmp/pod-trust.json \
  --query Role.Arn --output text)

aws iam attach-role-policy \
  --role-name SparkOnEKS-Role \
  --policy-arn ${SPARK_POLICY_ARN}

kubectl create serviceaccount spark -n spark

aws eks create-pod-identity-association \
  --cluster-name ${CLUSTER_NAME} \
  --namespace spark \
  --service-account spark \
  --role-arn ${SPARK_ROLE_ARN} \
  --region ${AWS_REGION}

kubectl create clusterrolebinding spark-rb \
  --clusterrole=edit \
  --serviceaccount=spark:spark 2>/dev/null || true

echo "Spark namespace 和权限已配置"
```

**预期输出**：打印"Spark namespace 和权限已配置"

### 3. 安装 Spark Operator

> **已验证：** spark-operator 2.5.1（kubeflow/spark-operator Helm chart 当前版本）的 `spark.jobNamespaces` 默认值是 `["default"]`——如果不显式指定，controller 只会 watch `default` namespace，提交到 `spark` namespace 的 SparkApplication 会被静默忽略（`status` 永远为空，不报错也不创建 Pod）。已在命令中加入 `--set spark.jobNamespaces="{spark}"`。

```bash
helm repo add spark-operator https://kubeflow.github.io/spark-operator
helm repo update

helm upgrade --install spark-operator spark-operator/spark-operator \
  --namespace spark-operator \
  --create-namespace \
  --set webhook.enable=true \
  --set spark.jobNamespaces="{spark}" \
  --wait \
  --timeout 5m

kubectl rollout status deployment/spark-operator-controller \
  -n spark-operator --timeout=5m 2>/dev/null || \
kubectl rollout status deployment/spark-operator \
  -n spark-operator --timeout=5m

echo "Spark Operator 安装完成"
```

**预期输出**：打印"Spark Operator 安装完成"

### 4. 提交 SparkApplication

> **注意：** 镜像用 `docker.io/apache/spark-py:v3.4.0`（`3.5.1` 系列 tag 在该镜像仓库不存在），`sparkVersion` 需同步设为 `3.4.0`。

> **注意（以下 5 处已在下方命令中修正）：**
> 1. spark-operator chart 默认只监听 `default` namespace，提交到 `spark` namespace 需加 `--set spark.jobNamespaces="{spark}"`，否则 controller 不会 reconcile
> 2. 镜像不含 `hadoop-aws`/`aws-java-sdk-bundle` 这两个 S3A 连接器 jar，需在 `sparkConf` 加 `spark.jars.packages` 显式引入
> 3. controller 容器以非 root 用户运行，Ivy 默认缓存目录不可写，需加 `spark.jars.ivy: "/tmp/.ivy2"`
> 4. `WebIdentityTokenCredentialsProvider` 是给 IRSA 设计的，本 Lab 用 Pod Identity，需改用 `IAMInstanceCredentialsProvider`，且 `aws-java-sdk-bundle` 需 ≥1.12.780（旧版本会拒绝 Pod Identity 的凭证 Full URI 主机）
> 5. `wordcount.py` 需用 `s3a://`（而非 `s3://`）并加 `inferSchema=True`，否则 `.sum("value")` 会因列类型报错

```bash
kubectl apply -n spark -f - <<EOF
apiVersion: sparkoperator.k8s.io/v1beta2
kind: SparkApplication
metadata:
  name: spark-wordcount
spec:
  type: Python
  pythonVersion: "3"
  mode: cluster
  image: docker.io/apache/spark-py:v3.4.0
  imagePullPolicy: Always
  mainApplicationFile: s3a://${SPARK_BUCKET}/scripts/wordcount.py
  sparkVersion: "3.4.0"
  restartPolicy:
    type: Never
  sparkConf:
    spark.jars.packages: "org.apache.hadoop:hadoop-aws:3.3.4,com.amazonaws:aws-java-sdk-bundle:1.12.780"
    spark.jars.ivy: "/tmp/.ivy2"
  hadoopConf:
    fs.s3a.aws.credentials.provider: org.apache.hadoop.fs.s3a.auth.IAMInstanceCredentialsProvider
  driver:
    cores: 1
    coreLimit: "1200m"
    memory: "512m"
    serviceAccount: spark
  executor:
    cores: 1
    instances: 2
    memory: "512m"
EOF

echo "等待 SparkApplication 完成（约 5-10 分钟）..."

for i in $(seq 1 30); do
  STATUS=$(kubectl get sparkapplication spark-wordcount -n spark \
    -o jsonpath='{.status.applicationState.state}' 2>/dev/null)
  echo "状态: ${STATUS}"
  [[ "${STATUS}" == "COMPLETED" ]] && break
  [[ "${STATUS}" == "FAILED" ]] && { echo "Spark 作业失败"; break; }
  sleep 30
done
```

**预期输出**：最终状态为 `COMPLETED`

```bash
echo "=== S3 输出 ==="
aws s3 ls s3://${SPARK_BUCKET}/output/ 2>/dev/null || echo "等待输出写入..."
```

### 5. 创建 EMR on EKS Virtual Cluster

> **注意：** `create-virtual-cluster` 除了 Job Execution Role 的 trust policy 外，还需要 EMR containers 的集群级 service-linked role 在目标 namespace 有 RBAC 权限，否则报 `ValidationException: Required resource spark not found on the cluster`。需先执行 `eksctl create iamidentitymapping --service-name "emr-containers"`（下方命令已包含）。
>
> **注意：** `EMRonEKS-JobRole` 除 `AmazonS3ReadOnlyAccess` 外还需要 `s3:PutObject`/`s3:DeleteObject`（`overwrite` 模式写输出前会先删除旧文件），已在下方补充 `EMRonEKS-S3Write` 内联策略。

```bash
eksctl create iamidentitymapping \
  --cluster ${CLUSTER_NAME} \
  --namespace spark \
  --service-name "emr-containers" \
  --region ${AWS_REGION}

cat > /tmp/emr-trust.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Service": "emr-containers.amazonaws.com"},
    "Action": "sts:AssumeRole"
  }]
}
EOF

EMR_JOB_ROLE_ARN=$(aws iam create-role \
  --role-name EMRonEKS-JobRole \
  --assume-role-policy-document file:///tmp/emr-trust.json \
  --query Role.Arn --output text)

aws iam attach-role-policy \
  --role-name EMRonEKS-JobRole \
  --policy-arn arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess

cat > /tmp/emr-s3-write-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": ["s3:PutObject", "s3:DeleteObject"],
    "Resource": "arn:aws:s3:::${SPARK_BUCKET}/*"
  }]
}
EOF

aws iam put-role-policy \
  --role-name EMRonEKS-JobRole \
  --policy-name EMRonEKS-S3Write \
  --policy-document file:///tmp/emr-s3-write-policy.json

aws emr-containers update-role-trust-policy \
  --cluster-name ${CLUSTER_NAME} \
  --namespace spark \
  --role-name EMRonEKS-JobRole \
  --region ${AWS_REGION} 2>/dev/null || true

EMR_CLUSTER_ID=$(aws emr-containers create-virtual-cluster \
  --name eks-spark-demo \
  --container-provider '{
    "id": "'"${CLUSTER_NAME}"'",
    "type": "EKS",
    "info": {"eksInfo": {"namespace": "spark"}}
  }' \
  --region ${AWS_REGION} \
  --query 'id' --output text)

echo "EMR Virtual Cluster ID: ${EMR_CLUSTER_ID}"

until [ "$(aws emr-containers describe-virtual-cluster \
  --id ${EMR_CLUSTER_ID} --region ${AWS_REGION} \
  --query 'virtualCluster.state' --output text)" = "RUNNING" ]; do
  echo "等待 EMR Virtual Cluster RUNNING..."
  sleep 15
done
echo "EMR Virtual Cluster RUNNING"
```

**预期输出**：打印"EMR Virtual Cluster RUNNING"

### 6. 提交 EMR Spark 作业

> **注意（以下 2 处已在下方修正）：**
> 1. EMR-on-EKS 走 IRSA（区别于第 4 步 SparkApplication 用的 Pod Identity），hadoop-aws 默认凭证链不含 IRSA 解析器，需在 `sparkSubmitParameters` 显式加 `--conf spark.hadoop.fs.s3a.aws.credentials.provider=com.amazonaws.auth.WebIdentityTokenCredentialsProvider`，否则报 `NoAuthWithAWSException`
> 2. `AmazonS3ReadOnlyAccess` 不含 `s3:DeleteObject`，`output/` 的 `overwrite` 模式会因无法删除旧文件而失败（已在第 5 步补充 `EMRonEKS-S3Write` 策略）
>
> 排查建议：给 Job Role 加 CloudWatch 日志权限并在 `start-job-run` 开启日志配置——EMR 失败的 job-runner/driver Pod 清理很快，不开日志基本看不到真实报错。

```bash
EMR_JOB_ID=$(aws emr-containers start-job-run \
  --virtual-cluster-id ${EMR_CLUSTER_ID} \
  --name emr-wordcount \
  --execution-role-arn ${EMR_JOB_ROLE_ARN} \
  --release-label emr-7.0.0-latest \
  --job-driver '{
    "sparkSubmitJobDriver": {
      "entryPoint": "s3://'"${SPARK_BUCKET}"'/scripts/wordcount.py",
      "sparkSubmitParameters": "--conf spark.executor.instances=2 --conf spark.hadoop.fs.s3a.aws.credentials.provider=com.amazonaws.auth.WebIdentityTokenCredentialsProvider"
    }
  }' \
  --region ${AWS_REGION} \
  --query 'id' --output text)

echo "EMR Job ID: ${EMR_JOB_ID}"
echo "等待 EMR 作业完成..."

for i in $(seq 1 20); do
  STATUS=$(aws emr-containers describe-job-run \
    --virtual-cluster-id ${EMR_CLUSTER_ID} \
    --id ${EMR_JOB_ID} \
    --region ${AWS_REGION} \
    --query 'jobRun.state' --output text 2>/dev/null)
  echo "EMR 状态: ${STATUS}"
  [[ "${STATUS}" == "COMPLETED" ]] && break
  [[ "${STATUS}" =~ FAILED|CANCELLED ]] && { echo "EMR 作业失败"; break; }
  sleep 60
done
```

**预期输出**：最终 EMR 状态为 `COMPLETED`。

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
| 1 | `kubectl get pods -n spark-operator --no-headers \| grep Running \| wc -l \| tr -d ' '` | 至少 `1` |
| 2 | `kubectl get sparkapplication spark-wordcount -n spark -o jsonpath='{.status.applicationState.state}'` | `COMPLETED` |
| 3 | `aws s3 ls s3://eks-spark-data-$(aws sts get-caller-identity --query Account --output text)/output/ --region us-east-1 2>/dev/null \| wc -l \| tr -d ' '` | 大于 `0` |
| 4 | `aws emr-containers describe-virtual-cluster --id $(aws emr-containers list-virtual-clusters --region us-east-1 --query 'virtualClusters[?name==\`eks-spark-demo\`].id' --output text) --region us-east-1 --query 'virtualCluster.state' --output text 2>/dev/null` | `RUNNING` |
| 5 | `EMR_CID=$(aws emr-containers list-virtual-clusters --region us-east-1 --query 'virtualClusters[?name==\`eks-spark-demo\`].id' --output text); aws emr-containers list-job-runs --virtual-cluster-id ${EMR_CID} --region us-east-1 --query 'jobRuns[0].state' --output text 2>/dev/null` | `COMPLETED` |

> **已验证（2026-07-16）：** 检查点 5 为新增项。此前文档只要求检查点 4（virtual cluster `RUNNING`），因为 EMR 作业本身长期被记录为"已知问题、未解决、不影响验收"。2026-07-16 在独立无干扰集群上完整重跑后确认第 6 步 EMR 作业可以稳定 `COMPLETED`（根因是 IRSA 凭证 Provider 未显式配置 + Job Role 缺少 S3 写权限，均已在第 5/6 步命令块中修正），因此补充检查点 5，要求 EMR 作业本身也必须 `COMPLETED`，不再豁免。

---

## 实验总结

本实验完成了「Spark on EKS」的全部操作，从资源创建到功能验证形成了完整闭环，**包括 EMR on EKS 作业本身的成功执行**（第 6 步，2026-07-16 确认可稳定复现 `COMPLETED`，不再是遗留的已知问题）。通过动手实践，你已掌握了 Spark Operator 和 EMR on EKS 两条技术路径在生产环境中的核心配置方法和最佳实践——尤其是 **Pod Identity 与 IRSA 两种凭证机制对 S3A 客户端配置的不同要求**，这是本 Lab 最容易踩坑、也最有实践价值的知识点。Lab07 将学习 Gateway API 与流量管理。

---

## 清理

> **已验证：** 若第 5 步执行过 `eksctl create iamidentitymapping --service-name "emr-containers"`，清理时应额外执行 `eksctl delete iamidentitymapping --cluster ${CLUSTER_NAME} --region ${AWS_REGION} --arn arn:aws:iam::${ACCOUNT_ID}:role/AWSServiceRoleForAmazonEMRContainers`，避免在 `aws-auth` ConfigMap 中残留该 Lab 专用的身份映射（已在下方命令块中补充）。

```bash
aws emr-containers delete-virtual-cluster \
  --id ${EMR_CLUSTER_ID} --region ${AWS_REGION} 2>/dev/null || true

eksctl delete iamidentitymapping --cluster ${CLUSTER_NAME} --region ${AWS_REGION} \
  --arn arn:aws:iam::${ACCOUNT_ID}:role/AWSServiceRoleForAmazonEMRContainers 2>/dev/null || true

kubectl delete sparkapplication spark-wordcount -n spark 2>/dev/null || true
helm uninstall spark-operator -n spark-operator 2>/dev/null || true
kubectl delete namespace spark spark-operator 2>/dev/null || true

for ASSOC in $(aws eks list-pod-identity-associations \
  --cluster-name ${CLUSTER_NAME} \
  --namespace spark \
  --service-account spark \
  --query 'associations[*].associationId' --output text 2>/dev/null); do
  aws eks delete-pod-identity-association \
    --cluster-name ${CLUSTER_NAME} \
    --association-id ${ASSOC} \
    --region ${AWS_REGION}
done

aws iam detach-role-policy \
  --role-name SparkOnEKS-Role \
  --policy-arn ${SPARK_POLICY_ARN} 2>/dev/null || true
aws iam delete-role --role-name SparkOnEKS-Role 2>/dev/null || true
aws iam delete-policy --policy-arn ${SPARK_POLICY_ARN} 2>/dev/null || true
aws iam delete-role-policy --role-name EMRonEKS-JobRole --policy-name EMRonEKS-S3Write 2>/dev/null || true
aws iam delete-role-policy --role-name EMRonEKS-JobRole --policy-name EMRonEKS-CloudWatchLogs 2>/dev/null || true
aws iam detach-role-policy \
  --role-name EMRonEKS-JobRole \
  --policy-arn arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess 2>/dev/null || true
aws iam delete-role --role-name EMRonEKS-JobRole 2>/dev/null || true

aws logs delete-log-group --log-group-name /emr-on-eks/eks-spark-demo --region ${AWS_REGION} 2>/dev/null || true

aws s3 rm s3://${SPARK_BUCKET} --recursive 2>/dev/null || true
aws s3 rb s3://${SPARK_BUCKET} 2>/dev/null || true

echo "清理完成"
```
