# Lab08 — CodePipeline 进行 EKS CI/CD

## 实验简介

本实验将完成「CodePipeline CI/CD」的全部操作，属于 EKS 进阶课程，面向有基础集群操作经验的学员。

**实验目标：**
- 掌握 CodePipeline CI/CD 的核心配置与操作流程
- 理解相关组件的架构原理和最佳实践
- 能够独立完成从部署到验证的完整闭环

**实验流程：**
1. 创建 ECR 仓库
2. 创建 CodeBuild IAM Role
3. 通过 EKS Access Entry 授权 CodeBuild Role
4. 创建应用代码和 Buildspec
5. 创建 S3 Artifact Bucket 和 CodeCommit 仓库
6. 创建 CodeBuild Project
7. 创建 CodePipeline
8. 验证首次部署

**预计 AI 执行时长：** 12-15 分钟


## 前提条件

- **工具**：AWS CLI v2、kubectl v1.35、Docker、git
- **权限**：AdministratorAccess（含 EKS、IAM、ECR、CodeCommit、CodeBuild、CodePipeline、S3、CloudWatch Logs）
- **前提**：EKS 集群可用，kubectl 可访问集群
- **初始化**：

```bash
export AWS_REGION=us-east-1
export AWS_DEFAULT_REGION=us-east-1
export CLUSTER_NAME=demo
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export APP_NAME=cicd-demo
export ECR_REPO=${APP_NAME}
```

---

## 步骤

### 1. 创建 ECR 仓库

```bash
aws ecr create-repository \
  --repository-name ${ECR_REPO} \
  --region ${AWS_REGION}

ECR_URI="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPO}"
echo "ECR URI: ${ECR_URI}"
```

**预期输出**：打印 ECR URI（内部记录，不输出完整 ARN 给用户）

### 2. 创建 CodeBuild IAM Role

```bash
cat > /tmp/codebuild-trust.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Service": "codebuild.amazonaws.com"},
    "Action": "sts:AssumeRole"
  }]
}
EOF

CODEBUILD_ROLE_ARN=$(aws iam create-role \
  --role-name EKS-CodeBuild-Role \
  --assume-role-policy-document file:///tmp/codebuild-trust.json \
  --query Role.Arn --output text)

aws iam attach-role-policy \
  --role-name EKS-CodeBuild-Role \
  --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPowerUser

cat > /tmp/codebuild-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["eks:DescribeCluster"],
      "Resource": "arn:aws:eks:${AWS_REGION}:${ACCOUNT_ID}:cluster/${CLUSTER_NAME}"
    },
    {
      "Effect": "Allow",
      "Action": ["logs:CreateLogGroup","logs:CreateLogStream","logs:PutLogEvents"],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": ["s3:GetObject","s3:PutObject","s3:GetBucketVersioning"],
      "Resource": ["arn:aws:s3:::${APP_NAME}-artifacts-${ACCOUNT_ID}/*",
                   "arn:aws:s3:::${APP_NAME}-artifacts-${ACCOUNT_ID}"]
    }
  ]
}
EOF

aws iam put-role-policy \
  --role-name EKS-CodeBuild-Role \
  --policy-name EKS-CodeBuild-Policy \
  --policy-document file:///tmp/codebuild-policy.json

echo "CodeBuild IAM Role 已创建"
```

**预期输出**：打印"CodeBuild IAM Role 已创建"

### 3. 通过 EKS Access Entry 授权 CodeBuild Role

```bash
aws eks create-access-entry \
  --cluster-name ${CLUSTER_NAME} \
  --principal-arn ${CODEBUILD_ROLE_ARN} \
  --type STANDARD \
  --region ${AWS_REGION}

aws eks associate-access-policy \
  --cluster-name ${CLUSTER_NAME} \
  --principal-arn ${CODEBUILD_ROLE_ARN} \
  --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy \
  --access-scope type=cluster \
  --region ${AWS_REGION}

echo "EKS Access Entry 已配置"
```

**预期输出**：打印"EKS Access Entry 已配置"

### 4. 创建应用代码和 Buildspec

```bash
mkdir -p /tmp/cicd-app/k8s

cat > /tmp/cicd-app/app.py << 'EOF'
from http.server import HTTPServer, BaseHTTPRequestHandler
import os

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        version = os.environ.get("APP_VERSION", "v1")
        self.send_response(200)
        self.end_headers()
        self.wfile.write(f"Hello from EKS CI/CD - {version}\n".encode())
    def log_message(self, *args): pass

HTTPServer(('', 8080), Handler).serve_forever()
EOF

cat > /tmp/cicd-app/Dockerfile << 'EOF'
FROM public.ecr.aws/docker/library/python:3.12-alpine
WORKDIR /app
COPY app.py .
EXPOSE 8080
CMD ["python3", "app.py"]
EOF

cat > /tmp/cicd-app/k8s/deployment.yaml << EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${APP_NAME}
  namespace: default
spec:
  replicas: 2
  selector:
    matchLabels:
      app: ${APP_NAME}
  template:
    metadata:
      labels:
        app: ${APP_NAME}
    spec:
      containers:
      - name: app
        image: IMAGE_PLACEHOLDER
        ports:
        - containerPort: 8080
        env:
        - name: APP_VERSION
          value: "v1"
        resources:
          requests:
            cpu: 100m
            memory: 64Mi
EOF

cat > /tmp/cicd-app/buildspec.yml << EOF
version: 0.2
phases:
  pre_build:
    commands:
      - ECR_URI="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPO}"
      - IMAGE_TAG=\$(date +%Y%m%d%H%M%S)
      - aws ecr get-login-password --region ${AWS_REGION} | docker login --username AWS --password-stdin \${ECR_URI%/*}
  build:
    commands:
      - docker build -t \${ECR_URI}:\${IMAGE_TAG} .
      - docker push \${ECR_URI}:\${IMAGE_TAG}
  post_build:
    commands:
      - aws eks update-kubeconfig --name ${CLUSTER_NAME} --region ${AWS_REGION}
      - sed -i "s|IMAGE_PLACEHOLDER|\${ECR_URI}:\${IMAGE_TAG}|" k8s/deployment.yaml
      - kubectl apply -f k8s/deployment.yaml
      - kubectl rollout status deployment/${APP_NAME} -n default --timeout=5m
      - echo "部署完成"
EOF

echo "应用代码已创建"
ls -la /tmp/cicd-app/
```

**预期输出**：打印应用文件列表

### 5. 创建 S3 Artifact Bucket 和 CodeCommit 仓库

```bash
ARTIFACT_BUCKET="${APP_NAME}-artifacts-${ACCOUNT_ID}"
aws s3 mb s3://${ARTIFACT_BUCKET} --region ${AWS_REGION}
aws s3api put-bucket-versioning \
  --bucket ${ARTIFACT_BUCKET} \
  --versioning-configuration Status=Enabled

aws codecommit create-repository \
  --repository-name ${APP_NAME} \
  --region ${AWS_REGION}

COMMIT_URL=$(aws codecommit get-repository \
  --repository-name ${APP_NAME} \
  --region ${AWS_REGION} \
  --query 'repositoryMetadata.cloneUrlHttp' --output text)

git config --global user.email "eks-lab@example.com" 2>/dev/null || true
git config --global user.name "EKS Lab" 2>/dev/null || true

cd /tmp/cicd-app
git init -b main 2>/dev/null || git init
git add .
git commit -m "Initial commit"
git remote add origin ${COMMIT_URL}
git push -u origin main \
  --config 'credential.helper=!aws codecommit credential-helper $@' \
  --config 'credential.UseHttpPath=true' 2>/dev/null || \
git -c credential.helper='!aws codecommit credential-helper $@' \
  -c credential.UseHttpPath=true push -u origin main

cd -
echo "代码已推送到 CodeCommit"
```

> **已验证：** 在多 agent 共享同一台操作机 / 同一份 `~/.gitconfig` 的场景下，`git push` 可能返回 `403 Forbidden`，原因不是权限不足，而是 `~/.gitconfig` 中已存在**其他并行任务写入的全局 `credential.helper`**（例如指向另一个 AWS profile 或另一个分区的 `aws --profile xxx codecommit credential-helper`）。由于 git 对多值配置项按 `system → global → local → command line` 顺序依次尝试，本步骤命令行传入的 `-c credential.helper=...` 会被追加在全局配置之后，若全局那条已经能返回一组（错误的）用户名密码，git 就会优先使用它，导致用错身份 / 错误分区凭证而 403。**排查方法**：`git config --global --get-all credential.helper` 查看是否已有其他 helper；**修复方法**：不要修改这份共享的全局配置（会影响其他并行 agent），而是在本次 push 命令前先用一次空值清空多值列表，再追加本实验需要的 helper：
>
> ```bash
> git -c credential.helper= \
>     -c credential.helper='!aws codecommit credential-helper $@' \
>     -c credential.UseHttpPath=true \
>     push -u origin main
> ```
>
> 空的 `-c credential.helper=` 会清空此前所有已定义的 helper（含全局配置里的），紧接着追加的 helper 才是唯一生效的一条，从而保证使用当前会话的正确身份，且不修改任何共享的全局文件。

**预期输出**：打印"代码已推送到 CodeCommit"

### 6. 创建 CodeBuild Project

```bash
aws codebuild create-project \
  --name ${APP_NAME}-build \
  --source '{"type":"CODECOMMIT","location":"'"${COMMIT_URL}"'","buildspec":"buildspec.yml"}' \
  --artifacts '{"type":"NO_ARTIFACTS"}' \
  --environment '{"type":"LINUX_CONTAINER","image":"aws/codebuild/standard:7.0","computeType":"BUILD_GENERAL1_SMALL","privilegedMode":true}' \
  --service-role ${CODEBUILD_ROLE_ARN} \
  --region ${AWS_REGION}

echo "CodeBuild Project 已创建"
```

**预期输出**：打印"CodeBuild Project 已创建"

### 7. 创建 CodePipeline

> **已验证：** 原文档直接复用第 2 步创建的 `CODEBUILD_ROLE_ARN`（`EKS-CodeBuild-Role`）作为 CodePipeline 的 `roleArn`，但该 Role 的信任策略只允许 `codebuild.amazonaws.com` 扮演，CodePipeline 服务（`codepipeline.amazonaws.com`）无权 AssumeRole，实测 `create-pipeline` 直接报错：`InvalidStructureException: CodePipeline is not authorized to perform AssumeRole on role ...`。CodePipeline 必须使用单独的、信任 `codepipeline.amazonaws.com` 的服务角色。已在本步骤前补充创建 `EKS-CodePipeline-Role`：
>
> ```bash
> cat > /tmp/codepipeline-trust.json << 'EOF'
> {
>   "Version": "2012-10-17",
>   "Statement": [{
>     "Effect": "Allow",
>     "Principal": {"Service": "codepipeline.amazonaws.com"},
>     "Action": "sts:AssumeRole"
>   }]
> }
> EOF
>
> CODEPIPELINE_ROLE_ARN=$(aws iam create-role \
>   --role-name EKS-CodePipeline-Role \
>   --assume-role-policy-document file:///tmp/codepipeline-trust.json \
>   --query Role.Arn --output text)
>
> cat > /tmp/codepipeline-policy.json << EOF
> {
>   "Version": "2012-10-17",
>   "Statement": [
>     {
>       "Effect": "Allow",
>       "Action": ["s3:GetObject","s3:PutObject","s3:GetBucketVersioning","s3:ListBucket"],
>       "Resource": ["arn:aws:s3:::${ARTIFACT_BUCKET}/*","arn:aws:s3:::${ARTIFACT_BUCKET}"]
>     },
>     {
>       "Effect": "Allow",
>       "Action": ["codecommit:GetBranch","codecommit:GetCommit","codecommit:UploadArchive","codecommit:GetUploadArchiveStatus","codecommit:CancelUploadArchive"],
>       "Resource": "arn:aws:codecommit:${AWS_REGION}:${ACCOUNT_ID}:${APP_NAME}"
>     },
>     {
>       "Effect": "Allow",
>       "Action": ["codebuild:BatchGetBuilds","codebuild:StartBuild"],
>       "Resource": "arn:aws:codebuild:${AWS_REGION}:${ACCOUNT_ID}:project/${APP_NAME}-build"
>     }
>   ]
> }
> EOF
>
> aws iam put-role-policy \
>   --role-name EKS-CodePipeline-Role \
>   --policy-name EKS-CodePipeline-Policy \
>   --policy-document file:///tmp/codepipeline-policy.json
> ```
>
> 随后下方 `codepipeline-def.json` 中的 `roleArn` 需改为 `${CODEPIPELINE_ROLE_ARN}`（而非 `${CODEBUILD_ROLE_ARN}`）。清理阶段也需要额外删除该角色（见"清理"章节的补充说明）。

```bash
cat > /tmp/codepipeline-def.json << EOF
{
  "name": "${APP_NAME}-pipeline",
  "roleArn": "${CODEPIPELINE_ROLE_ARN}",
  "artifactStore": {
    "type": "S3",
    "location": "${ARTIFACT_BUCKET}"
  },
  "stages": [
    {
      "name": "Source",
      "actions": [{
        "name": "Source",
        "actionTypeId": {
          "category": "Source",
          "owner": "AWS",
          "provider": "CodeCommit",
          "version": "1"
        },
        "configuration": {
          "RepositoryName": "${APP_NAME}",
          "BranchName": "main"
        },
        "outputArtifacts": [{"name": "SourceOutput"}]
      }]
    },
    {
      "name": "Build",
      "actions": [{
        "name": "Build",
        "actionTypeId": {
          "category": "Build",
          "owner": "AWS",
          "provider": "CodeBuild",
          "version": "1"
        },
        "configuration": {"ProjectName": "${APP_NAME}-build"},
        "inputArtifacts": [{"name": "SourceOutput"}]
      }]
    }
  ]
}
EOF

aws codepipeline create-pipeline \
  --pipeline file:///tmp/codepipeline-def.json \
  --region ${AWS_REGION}

echo "等待流水线执行完成（约 3-5 分钟）..."
for i in $(seq 1 20); do
  STATUS=$(aws codepipeline get-pipeline-state \
    --name ${APP_NAME}-pipeline \
    --region ${AWS_REGION} \
    --query 'stageStates[?stageName==`Build`].latestExecution.status' \
    --output text 2>/dev/null)
  echo "Build 状态: ${STATUS}"
  [[ "${STATUS}" == "Succeeded" ]] && break
  [[ "${STATUS}" == "Failed" ]] && { echo "构建失败，请检查 CodeBuild 日志"; break; }
  sleep 30
done
```

**预期输出**：Build 状态为 `Succeeded`，应用部署到 EKS。

### 8. 验证首次部署

```bash
kubectl get deployment ${APP_NAME} -n default
kubectl get pods -l app=${APP_NAME} -n default
```

**预期输出**：Deployment 就绪，Pod Running。

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
| 1 | `aws eks describe-access-entry --cluster-name demo --principal-arn arn:aws:iam::$(aws sts get-caller-identity --query Account --output text):role/EKS-CodeBuild-Role --region us-east-1 --query 'accessEntry.type' --output text` | `STANDARD` |
| 2 | `aws ecr describe-repositories --repository-names cicd-demo --region us-east-1 --query 'repositories[0].repositoryName' --output text` | `cicd-demo` |
| 3 | `aws codepipeline get-pipeline-state --name cicd-demo-pipeline --region us-east-1 --query 'stageStates[?stageName==\`Build\`].latestExecution.status' --output text` | `Succeeded` |
| 4 | `kubectl get deployment cicd-demo -n default -o jsonpath='{.status.readyReplicas}'` | `2` |

---

## 实验总结

本实验完成了「CodePipeline CI/CD」的全部操作，从资源创建到功能验证形成了完整闭环。通过动手实践，你已掌握了相关组件在生产环境中的核心配置方法和最佳实践。Lab09 将学习 OpenSearch 日志平台。

---

## 清理

```bash
aws codepipeline delete-pipeline --name ${APP_NAME}-pipeline --region ${AWS_REGION} 2>/dev/null || true
aws codebuild delete-project --name ${APP_NAME}-build --region ${AWS_REGION} 2>/dev/null || true
aws codecommit delete-repository --repository-name ${APP_NAME} --region ${AWS_REGION} 2>/dev/null || true

aws ecr delete-repository \
  --repository-name ${ECR_REPO} \
  --force \
  --region ${AWS_REGION} 2>/dev/null || true

aws s3 rm s3://${ARTIFACT_BUCKET} --recursive 2>/dev/null || true
aws s3 rb s3://${ARTIFACT_BUCKET} 2>/dev/null || true
# 已验证：Bucket 在第 5 步开启了版本控制（put-bucket-versioning），`s3 rm --recursive`
# 只会在最新版本上打删除标记，历史版本对象仍然存在，导致 `s3 rb` 报 BucketNotEmpty。
# 若上面的 `aws s3 rb` 失败，需先清空所有历史版本和删除标记再重试：
aws s3api list-object-versions --bucket ${ARTIFACT_BUCKET} --output json \
  --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}' > /tmp/lab08-versions.json 2>/dev/null
aws s3api list-object-versions --bucket ${ARTIFACT_BUCKET} --output json \
  --query '{Objects: DeleteMarkers[].{Key:Key,VersionId:VersionId}}' > /tmp/lab08-markers.json 2>/dev/null
[ "$(jq '.Objects | length' /tmp/lab08-versions.json 2>/dev/null)" -gt 0 ] 2>/dev/null && \
  aws s3api delete-objects --bucket ${ARTIFACT_BUCKET} --delete file:///tmp/lab08-versions.json
[ "$(jq '.Objects | length' /tmp/lab08-markers.json 2>/dev/null)" -gt 0 ] 2>/dev/null && \
  aws s3api delete-objects --bucket ${ARTIFACT_BUCKET} --delete file:///tmp/lab08-markers.json
aws s3 rb s3://${ARTIFACT_BUCKET} 2>/dev/null || true

kubectl delete deployment ${APP_NAME} -n default 2>/dev/null || true

aws eks delete-access-entry \
  --cluster-name ${CLUSTER_NAME} \
  --principal-arn ${CODEBUILD_ROLE_ARN} \
  --region ${AWS_REGION} 2>/dev/null || true

aws iam delete-role-policy --role-name EKS-CodeBuild-Role --policy-name EKS-CodeBuild-Policy 2>/dev/null || true
aws iam detach-role-policy \
  --role-name EKS-CodeBuild-Role \
  --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPowerUser 2>/dev/null || true
aws iam delete-role --role-name EKS-CodeBuild-Role 2>/dev/null || true

# 补充：第 7 步新建的 CodePipeline 专用角色（见"已验证"说明）也需要清理
aws iam delete-role-policy --role-name EKS-CodePipeline-Role --policy-name EKS-CodePipeline-Policy 2>/dev/null || true
aws iam delete-role --role-name EKS-CodePipeline-Role 2>/dev/null || true

rm -rf /tmp/cicd-app
echo "清理完成"
```
