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

> **已验证：** 原示例镜像 `public.ecr.aws/docker/library/apache/spark-py:3.5.1-python3` 实际不存在（该仓库路径下没有这个镜像，`docker manifest inspect` 返回 `no such manifest`），且 Docker Hub 官方 `apache/spark-py` 也没有 `3.5.1` 系列 tag（最新到 `v3.4.0`）。已改用已验证可拉取的 `docker.io/apache/spark-py:v3.4.0`，并同步把 `sparkVersion` 改成 `3.4.0`。

> **已验证（2026-07-08 实测，共发现并修正 5 个真实 bug 才使作业跑通）：**
> 1. **spark-operator 2.5.1 Helm chart 默认只监听 `default` namespace**（`spark.jobNamespaces` 默认值为 `["default"]`），第 3 步若不显式设置，SparkApplication 提交到 `spark` namespace 后 controller 永远不会 reconcile（既不报错也不创建任何 Pod，`status` 一直为空）。第 3 步 `helm upgrade --install` 命令必须加 `--set spark.jobNamespaces="{spark}"`（已同步更新到第 3 步命令块）。
> 2. `docker.io/apache/spark-py:v3.4.0` **镜像本身不包含 hadoop-aws / aws-java-sdk-bundle 这两个 S3A 连接器 jar**（`/opt/spark/jars` 下确认没有），直接用 `s3a://` 路径会报 `ClassNotFoundException: org.apache.hadoop.fs.s3a.S3AFileSystem`。需要在 `sparkConf` 里加 `spark.jars.packages: "org.apache.hadoop:hadoop-aws:3.3.4,com.amazonaws:aws-java-sdk-bundle:1.12.780"`（版本需与镜像自带的 `hadoop-client-*-3.3.4.jar` 匹配；`aws-java-sdk-bundle` 必须 ≥1.12.5xx，见第 4 点）。
> 3. spark-operator controller 容器本身内置了一份 Spark 发行版并在自己的 Pod 里本地执行 `spark-submit`（含 Ivy 依赖解析），但该容器以非 root 用户运行且 `HOME=/nonexistent`，Ivy 默认缓存目录不可写，会导致 `FileNotFoundException: /nonexistent/.ivy2.5.2/cache/...`。需要额外加 `spark.jars.ivy: "/tmp/.ivy2"`（`/tmp` 在该容器内可写）指定一个可写的 Ivy 缓存路径。
> 4. 原 `hadoopConf.fs.s3a.aws.credentials.provider: com.amazonaws.auth.WebIdentityTokenCredentialsProvider` **是为 IRSA（OIDC Web Identity 联合）设计的**，读取的是 `AWS_ROLE_ARN` / `AWS_WEB_IDENTITY_TOKEN_FILE` 环境变量；但本 Lab 用的是 **EKS Pod Identity**，Pod 里实际注入的是 `AWS_CONTAINER_CREDENTIALS_FULL_URI`（值形如 `http://169.254.170.23/v1/credentials`）和 `AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE`，两者机制不匹配，会导致 `NullPointerException: You must specify a value for roleArn and roleSessionName`。此外，`aws-java-sdk-bundle` 若使用 hadoop-aws 3.3.4 默认关联的旧版本（1.12.262），其内置的 `ContainerCredentialsProvider` 会因安全校验拒绝 `169.254.170.23` 这个非 `localhost/127.0.0.1` 的 Full URI 主机（`Host can only be one of [localhost, 127.0.0.1]`，这是 EKS Pod Identity 支持在 SDK v1 ~1.12.499 之后才修复的已知限制）。已修正为：`hadoopConf.fs.s3a.aws.credentials.provider: org.apache.hadoop.fs.s3a.auth.IAMInstanceCredentialsProvider`，并将 `aws-java-sdk-bundle` 版本提升到 `1.12.780`（见上）。
> 5. `wordcount.py` 脚本本身有两处 bug：① 用的是 `s3://` scheme，但集群只注册了 `s3a://`（S3AFileSystem），必须统一改成 `s3a://`；② `spark.read.csv(..., header=True)` 不加 `inferSchema=True` 时所有列（含 `value`）都是 string 类型，`.sum("value")` 会报 `AnalysisException: "value" is not a numeric column`。已修正脚本为 `s3a://` + `inferSchema=True`（步骤 1 的脚本生成命令块已同步更新）。
>
> 另外，本 Lab 共享的 `demo` 集群上 `aws-load-balancer-controller`（非本 Lab 资源）曾因其他并发 Lab 触发的 Gateway API TLSRoute CRD 问题间歇性 CrashLoopBackOff，导致其 `mservice.elbv2.k8s.aws` Service 准入 Webhook 短暂无可用 endpoint，使 `spark-submit` 创建 driver headless Service 时报 `no endpoints available for service "aws-load-balancer-webhook-service"`。这是共享集群上与 Spark 无关的瞬时抖动，未修改该组件，实测重试提交（删除并重新 apply SparkApplication）即可绕过。

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

> **已验证：** 原文档只调用了 `aws emr-containers update-role-trust-policy`（这只是给 Job Execution Role 补 trust policy，用于*运行作业*时的权限），但 `create-virtual-cluster` 本身还需要 EMR containers 的**集群级 service-linked role**（`AWSServiceRoleForAmazonEMRContainers`）在目标 namespace 里有 Kubernetes RBAC 权限（Role + RoleBinding），否则会直接报错 `ValidationException: Required resource spark not found on the cluster`。必须先执行 `eksctl create iamidentitymapping --cluster ${CLUSTER_NAME} --namespace spark --service-name "emr-containers" --region ${AWS_REGION}`（eksctl 内置了对 `emr-containers` service-name 的支持，会自动创建对应的 Role/RoleBinding 并把 `AWSServiceRoleForAmazonEMRContainers` 加入 aws-auth ConfigMap），再调用 `create-virtual-cluster` 才能成功。已在下方命令块中补充该步骤。
>
> **已验证（2026-07-16）：** `EMRonEKS-JobRole` 除 `AmazonS3ReadOnlyAccess` 外还需要额外的 `s3:PutObject`/`s3:DeleteObject` 权限（第 6 步作业需要写输出且 `mode("overwrite")` 会先删除已存在的旧文件），否则第 6 步会在写输出阶段报 `AccessDenied`。已在下方命令块中补充 `EMRonEKS-S3Write` 内联策略。

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

> **已解决（2026-07-16，独立集群完整重跑验证）：** 此前（2026-07-08 首次 + 2026-07-15 两次局部重测）记录的"EMR 内置 AWS SDK v2 客户端稳定 403、疑似账号级安全基线限制"这一假设，在共享集群上三次尝试全部因环境抖动（网络/调度/CNI IP 耗尽）败在更早阶段，**从未真正验证过**。本次在完全独立、无并发干扰的集群上完整重跑，作业顺利跑到访问 S3 的阶段，实际暴露的是两个可直接修复的真实问题（均已在下方命令块和第 5 步中修正），与 SDK v2/账号安全基线无关：
> 1. **默认 S3A 凭证提供链不含 IRSA 解析器**：不显式指定时，100% 复现 `NoAuthWithAWSException: No AWS Credentials provided by TemporaryAWSCredentialsProvider SimpleAWSCredentialsProvider EnvironmentVariableCredentialsProvider IAMInstanceCredentialsProvider`（完全无凭证，不是被拒绝）。原因：EMR-on-EKS 走 **IRSA**（`AssumeRoleWithWebIdentity`，区别于第 4 步 SparkApplication 用的 Pod Identity），但 hadoop-aws 默认凭证链不含任何能读取 `AWS_WEB_IDENTITY_TOKEN_FILE`/`AWS_ROLE_ARN` 的 Provider。必须在 `sparkSubmitParameters` 显式加 `--conf spark.hadoop.fs.s3a.aws.credentials.provider=com.amazonaws.auth.WebIdentityTokenCredentialsProvider`（已在下方命令块加入）。
> 2. **Job Role 只读权限无法覆盖已存在的输出文件**：修完凭证问题后作业完整跑通读取+计算+写入，最后败在 `output/` 目录 `overwrite` 模式需要先删除旧文件，`AmazonS3ReadOnlyAccess` 不含 `s3:DeleteObject`（已在第 5 步补充 `EMRonEKS-S3Write` 内联策略解决）。
>
> 建议排查此类问题时给 Job Role 加 CloudWatch 日志（`logs:CreateLogGroup/CreateLogStream/PutLogEvents/DescribeLogStreams/DescribeLogGroups`）并在 `start-job-run` 加 `configuration-overrides.monitoringConfiguration.cloudWatchMonitoringConfiguration`——EMR job-runner/driver Pod 失败后清理极快（数秒到数十秒），不开日志基本看不到真实报错。详细排查过程见 `execution-records/execution-log-lab06.md` 中「Lab06 全新独立集群完整重跑（2026-07-16）」一节。

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
