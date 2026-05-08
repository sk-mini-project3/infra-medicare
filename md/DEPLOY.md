# 의료 서비스 인프라 배포 가이드

## 전체 흐름 한눈에 보기

```
[최초 1회 - AWS 계정 설정 ~ 클러스터 생성]
로컬 PC                     GitHub                      AWS
─────────────────────────────────────────────────────────────────
① 도구 설치 (Docker, Terraform, AWS CLI, kubectl)
② aws configure (IAM 키 등록)
③ S3 버킷 & DynamoDB 테이블 생성 (Terraform 상태 보관용)
④ Terraform Phase 1 apply (ECR, VPC, Aurora)
⑤ Terraform Phase 2 apply (EKS)
⑥ Terraform output 확인
⑦ aws eks update-kubeconfig
⑧ ArgoCD 설치 및 설정
                            ⑨ 4개 GitHub 레포 생성
                            ⑩ Secrets 등록
[이후 매번 - 코드 커밋 ~ 배포]
개발자                      GitHub Actions             AWS EKS (ArgoCD)
──────────────────────────────────────────────────────────────────
① 코드 수정 → git push main
                            ② 자동 빌드 (Docker)
                            ③ ECR 푸시
                            ④ infra-medicare 커밋
                            ⑤ kustomization.yaml 이미지 태그 수정
                                                    ⑥ ArgoCD 감지 → 동기화
                                                    ⑦ 롤링 업데이트
```

---

## Phase 1. 로컬 PC 사전 준비 (최초 1회)

### 1-1. 도구 설치 확인

필수 도구 버전 요구사항:

```bash
docker --version          # Docker >= 20.10
aws --version             # AWS CLI v2
terraform -version        # >= 1.3.0
kubectl version --client  # >= 1.24
git --version
```

**설치 링크**
- AWS CLI: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html
- Terraform: https://developer.hashicorp.com/terraform/install
- kubectl: https://kubernetes.io/docs/tasks/tools/
- Docker: https://docs.docker.com/get-docker/
- Helm(선택): https://helm.sh/docs/intro/install/

### 1-2. AWS IAM 사용자 생성 및 CLI 설정

AWS 콘솔에서 진행합니다.

#### 스텝 1: IAM 사용자 생성

1. AWS 콘솔 → **IAM** → **사용자** → **사용자 생성**
2. 사용자 이름: `terraform-admin` (또는 원하는 이름)
3. **권한 정책** 연결:
   - 직접 정책 연결
   - `AdministratorAccess` 선택 (**실습용. 운영 환경에서는 최소 권한 원칙 적용**)
4. **액세스 키 생성** (CLI용):
   - 키 유형: **액세스 키**
   - CSV 다운로드하여 안전하게 보관

#### 스텝 2: AWS CLI 설정

```bash
aws configure

# 입력값:
# AWS Access Key ID     : [위에서 생성한 키]
# AWS Secret Access Key : [위에서 생성한 시크릿]
# Default region name   : ap-northeast-2
# Default output format : json
```

설정 확인:
```bash
aws sts get-caller-identity
```

---

## Phase 2. Terraform State 백엔드 설정 (최초 1회)

Terraform 상태 파일을 S3에 저장하고 DynamoDB로 Lock 관리합니다.

### 2-1. S3 버킷 생성

```bash
# 변수 설정 (자신의 조직 / 프로젝트명으로 변경)
BUCKET_NAME="medical-service-tf-state-$(date +%s)"  # 고유 버킷명 생성
REGION="ap-northeast-2"

# S3 버킷 생성
aws s3api create-bucket \
  --bucket "$BUCKET_NAME" \
  --region "$REGION" \
  --create-bucket-configuration LocationConstraint=$REGION

# 버킷 버전 관리 활성화 (상태 파일 복구 가능)
aws s3api put-bucket-versioning \
  --bucket "$BUCKET_NAME" \
  --versioning-configuration Status=Enabled

# 버킷 암호화 활성화
aws s3api put-bucket-encryption \
  --bucket "$BUCKET_NAME" \
  --server-side-encryption-configuration '{
    "Rules": [{
      "ApplyServerSideEncryptionByDefault": {
        "SSEAlgorithm": "AES256"
      }
    }]
  }'

# 퍼블릭 액세스 차단
aws s3api put-public-access-block \
  --bucket "$BUCKET_NAME" \
  --public-access-block-configuration \
  "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

echo "✓ S3 버킷 생성 완료: $BUCKET_NAME"
```

### 2-2. DynamoDB Lock 테이블 생성

```bash
TABLE_NAME="medical-service-tf-lock"

aws dynamodb create-table \
  --table-name "$TABLE_NAME" \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region "$REGION"

echo "✓ DynamoDB 테이블 생성 완료: $TABLE_NAME"
```

### 2-3. Terraform Backend 초기화

`infra-medicare` 로컬 디렉토리에서:

```bash
cd medical-service-infra/terraform

# backend 초기화 (위에서 생성한 S3 & DynamoDB 정보 입력)
terraform init \
  -backend-config="bucket=YOUR_BUCKET_NAME" \
  -backend-config="key=medical-service/terraform.tfstate" \
  -backend-config="region=ap-northeast-2" \
  -backend-config="dynamodb_table=medical-service-tf-lock"

# 초기화 확인
terraform validate
```

---

## Phase 3. Terraform Phase 1: ECR, VPC, Aurora 생성

### 3-1. terraform.tfvars 설정

```bash
cd medical-service-infra/terraform

# 예시 파일 복사
cp terraform.tfvars.example terraform.tfvars
```

**terraform.tfvars 에서 반드시 변경할 항목:**

```hcl
db_password = "YourStrongPassword123!"  # ← 강력한 비밀번호로 변경
# 기타 변수(vpc_cidr, db_instance_class 등)는 기본값 사용 가능
```

외부 HeidiSQL 접속을 잠깐 허용하려면 아래처럼 바꿉니다.

```hcl
db_publicly_accessible = true
db_allowed_cidrs       = ["내_공인_IP/32"]
```

테스트가 끝나면 `db_publicly_accessible = false`로 돌리거나 `db_allowed_cidrs`를 VPC CIDR로 되돌리는 편이 안전합니다.

### 3-2. Phase 1 Apply (ECR, VPC, Aurora만 생성)

```bash
# 생성될 리소스 미리 확인 (ECR, VPC, RDS Aurora)
terraform plan -target=aws_ecr_repository.frontend \
                -target=aws_ecr_repository.backend \
                -target=aws_ecr_repository.ai \
                -target=aws_vpc.main \
                -target=aws_subnet.public \
                -target=aws_subnet.private \
                -target=aws_rds_cluster.aurora \
                -target=aws_rds_cluster_instance.aurora_primary

# Apply 실행
terraform apply -target=aws_ecr_repository.frontend \
                -target=aws_ecr_repository.backend \
                -target=aws_ecr_repository.ai \
                -target=aws_vpc.main \
                -target=aws_subnet.public \
                -target=aws_subnet.private \
                -target=aws_rds_cluster.aurora \
                -target=aws_rds_cluster_instance.aurora_primary

# yes 입력하면 5~10분 소요
```

**생성되는 리소스:**
| 리소스 | 설명 |
|--------|------|
| ECR 리포지토리 × 3 | frontend, backend, ai 이미지 저장소 |
| VPC | 10.0.0.0/16 CIDR |
| 퍼블릭 서브넷 × 2 | ALB 용 |
| 프라이빗 서브넷 × 2 | EKS 노드 용 |
| Aurora MySQL | db.t3.medium, 프라이빗 서브넷 배치 |
| 보안 그룹 | 통신 규칙 |

### 3-3. Phase 1 Output 확인

```bash
terraform output ecr_frontend_repository
terraform output ecr_backend_repository
terraform output ecr_ai_repository
terraform output rds_address
terraform output rds_endpoint
```

**출력값 예시:**
```
ecr_frontend_repository = "123456789012.dkr.ecr.ap-northeast-2.amazonaws.com/medical-service-frontend"
ecr_backend_repository = "123456789012.dkr.ecr.ap-northeast-2.amazonaws.com/medical-service-backend"
ecr_ai_repository = "123456789012.dkr.ecr.ap-northeast-2.amazonaws.com/medical-service-ai"
rds_address = "medical-service-aurora.xxxxx.ap-northeast-2.rds.amazonaws.com"
```

이 값들을 기록해두세요. 나중에 GitHub Secrets 및 kustomization.yaml에 사용됩니다.

---

## Phase 4. Terraform Phase 2: EKS 클러스터 생성

### 4-1. Phase 2 Apply (EKS 클러스터 & 노드 그룹)

```bash
# 이제 전체 리소스 생성 (Phase 1에서 생성된 것은 스킵)
terraform apply

# yes 입력하면 15~20분 소요 (EKS 클러스터 생성 시간)
```

**생성되는 리소스:**
| 리소스 | 설명 |
|--------|------|
| EKS 클러스터 | Kubernetes 1.27 |
| 노드 그룹 | t3.medium × 2대 (최소 1, 최대 4) |
| IAM 역할 | 클러스터, 노드, IRSA용 |
| 로드 밸런서(선택) | 나중에 ArgoCD/App용 |

### 4-2. EKS 클러스터 접근 설정

```bash
# kubeconfig 업데이트
aws eks update-kubeconfig \
  --region ap-northeast-2 \
  --name medical-service

# 연결 확인
kubectl cluster-info
kubectl get nodes
```

**예상 출력:**
```
NAME                                    STATUS   ROLES    AGE   VERSION
ip-10-0-11-xxx.ap-northeast-2.compute.internal   Ready    <none>   2m    v1.27.x
ip-10-0-12-xxx.ap-northeast-2.compute.internal   Ready    <none>   2m    v1.27.x
```

### 4-3. DB Secret 생성 (실제 값 주입 위치)

`k8s/base/secret.yaml`에는 실제 비밀번호를 적지 않습니다. DB 접속 정보는 EKS에 Secret으로 주입합니다.

```bash
# terraform output에서 Aurora 엔드포인트 확인
RDS_ENDPOINT=$(terraform -chdir=medical-service-infra/terraform output -raw rds_address)

# 실제 값은 로컬 터미널에서만 입력
DB_NAME=medicalservicedb
DB_USERNAME=admin
DB_PASSWORD='여기에_실제_비밀번호'

kubectl create secret generic db-credentials \
  --namespace default \
  --from-literal=DB_USERNAME="$DB_USERNAME" \
  --from-literal=DB_PASSWORD="$DB_PASSWORD" \
  --from-literal=DATABASE_URL="jdbc:mysql://${DB_USERNAME}:${DB_PASSWORD}@${RDS_ENDPOINT}:3306/${DB_NAME}"
```

이미 `k8s/base/secret.yaml`를 적용할 계획이면, 위 명령으로 만든 Secret이 우선 사용되도록 하거나, 배포 전에 `secret.yaml`을 `kubectl apply` 하지 말고 Secret 생성 명령만 사용하세요. 값이 들어간 Secret 파일을 GitHub에 커밋하면 안 됩니다.

---

## Phase 5. GitHub 설정

### 5-1. 4개 GitHub 레포 생성

콘솔이나 GitHub CLI에서 다음 4개 레포를 생성합니다:

- `frontend-medicare` (Dockerfile 포함한 프론트엔드)
- `backend-medicare` (Spring Boot 또는 Node.js 백엔드)
- `ai-medicare` (FastAPI AI 서비스)
- `infra-medicare` (Terraform, k8s 매니페스트, ArgoCD 설정)

각 레포를 로컬에 클론:

```bash
git clone https://github.com/YOUR_ORG/frontend-medicare.git
git clone https://github.com/YOUR_ORG/backend-medicare.git
git clone https://github.com/YOUR_ORG/ai-medicare.git
git clone https://github.com/YOUR_ORG/infra-medicare.git
```

### 5-2. GitHub Secrets 등록 (항목별 정리)

각 레포에서 **Settings → Secrets and variables → Actions** 로 이동해 아래 값들을 등록합니다.

**필수 정보:**
- **AWS_ACCOUNT_ID**: 12자리 AWS 계정 ID (예: `123456789012`)
- **AWS_ACCESS_KEY_ID**: IAM 사용자의 액세스 키
- **AWS_SECRET_ACCESS_KEY**: IAM 사용자의 시크릿 키
- **ECR_URI 패턴**: `{AWS_ACCOUNT_ID}.dkr.ecr.ap-northeast-2.amazonaws.com/{REPO_NAME}`

**중요:** 여기서 등록하는 값은 Docker 이미지 빌드/푸시용 GitHub Secrets입니다. DB 접속 정보(DB_USERNAME, DB_PASSWORD, DATABASE_URL)는 backend가 Kubernetes에서 실행될 때 쓰는 런타임 값이므로, [k8s/base/secret.yaml](../k8s/base/secret.yaml) 같은 Kubernetes Secret으로 관리합니다. 현재 구조에서는 AI 서비스가 DB를 직접 사용하지 않으므로 DB 시크릿이 필요하지 않습니다.

#### ① `frontend-medicare` 레포

```
AWS_ACCOUNT_ID                 = 123456789012
AWS_ACCESS_KEY_ID              = AKIAIOSFODNN7EXAMPLE
AWS_SECRET_ACCESS_KEY          = wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
ECR_REPOSITORY                 = medical-service-frontend
```

**CI에서 사용되는 형태:**
```
ECR_URI = 296336226405.dkr.ecr.ap-northeast-2.amazonaws.com/medical-service-frontend
```

#### ② `backend-medicare` 레포

```
AWS_ACCOUNT_ID                 = 123456789012
AWS_ACCESS_KEY_ID              = AKIAIOSFODNN7EXAMPLE
AWS_SECRET_ACCESS_KEY          = wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
ECR_REPOSITORY                 = medical-service-backend
```

**CI에서 사용되는 형태:**
```
ECR_URI = 296336226405.dkr.ecr.ap-northeast-2.amazonaws.com/medical-service-backend
```

#### ③ `ai-medicare` 레포

```
AWS_ACCOUNT_ID                 = 123456789012
AWS_ACCESS_KEY_ID              = AKIAIOSFODNN7EXAMPLE
AWS_SECRET_ACCESS_KEY          = wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
ECR_REPOSITORY                 = medical-service-ai
```

**CI에서 사용되는 형태:**
```
ECR_URI = 296336226405.dkr.ecr.ap-northeast-2.amazonaws.com/medical-service-ai
```

#### ④ `infra-medicare` 레포

```
AWS_ACCOUNT_ID                 = 123456789012
AWS_ACCESS_KEY_ID              = AKIAIOSFODNN7EXAMPLE
AWS_SECRET_ACCESS_KEY          = wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
```

**참고:** Terraform을 GitHub Actions에서 실행하거나 자동 이미지 태그 업데이트가 필요할 때만 위 값들을 등록합니다. 현재 구조에서는 수동 이미지 업데이트를 사용하므로 필수가 아닙니다.

### 5-2-1. Secrets 값 확인 명령어

AWS CLI로 자신의 AWS 계정 ID와 액세스 키 정보를 확인할 수 있습니다:

```bash
# AWS 계정 ID 확인
aws sts get-caller-identity --query Account --output text

# 현재 IAM 사용자명 확인
aws sts get-caller-identity --query Arn --output text

# ECR URI 확인 (Terraform output)
cd medical-service-infra/terraform
terraform output ecr_frontend_repository
terraform output ecr_backend_repository
terraform output ecr_ai_repository
```

**출력 예시:**
```
Account:              296336226405
ECR_URI (frontend):   296336226405.dkr.ecr.ap-northeast-2.amazonaws.com/medical-service-frontend
ECR_URI (backend):    296336226405.dkr.ecr.ap-northeast-2.amazonaws.com/medical-service-backend
ECR_URI (ai):         296336226405.dkr.ecr.ap-northeast-2.amazonaws.com/medical-service-ai
```

### 5-3. 코드 푸시

각 서비스 레포에 코드(Dockerfile 포함)를 푸시하면 GitHub Actions 워크플로가 자동으로 트리거됩니다:

```bash
cd frontend-medicare
git add .
git commit -m "feat: initial frontend scaffolding"
git push origin main

# 유사하게 backend, ai도 푸시
```

### 5-3-1. GitHub Actions 전에 Docker 로컬 확인

GitHub Actions가 돌기 전에 각 서비스 이미지를 로컬에서 한 번씩 빌드/실행해보면, Dockerfile이나 실행 환경 문제를 먼저 잡을 수 있습니다.

```bash
# frontend
cd frontend-medicare
docker build -t medical-service-frontend:local .
docker run --rm -p 8080:80 medical-service-frontend:local

# backend
cd ../backend-medicare
docker build -t medical-service-backend:local .
docker run --rm -p 3000:3000 \
  -e LOG_LEVEL=info \
  -e AI_BASE_URL=http://host.docker.internal:8001 \
  -e DATABASE_URL="jdbc:mysql://admin:password@host.docker.internal:3306/medicalservicedb" \
  -e DB_USERNAME=admin \
  -e DB_PASSWORD=password \
  medical-service-backend:local

# ai
cd ../ai-medicare
docker build -t medical-service-ai:local .
docker run --rm -p 8001:8001 \
  -e LOG_LEVEL=info \
  -e BACKEND_API_URL=http://host.docker.internal:3000 \
  medical-service-ai:local
```

필요하면 `docker run` 대신 `docker compose up`으로 묶어서 실행해도 됩니다. 핵심은 GitHub Actions로 올리기 전에 각 이미지가 로컬에서 정상 기동하는지 확인하는 것입니다.

### 5-4. CI 실행 확인

각 레포의 **Actions** 탭에서 워크플로 실행 상태를 확인합니다:

- ✅ **초록색**: 성공 (이미지가 ECR에 푸시됨)
- ❌ **빨간색**: 실패 (Secrets 값 오류, 빌드 오류 등 확인 필요)

**실패 원인 확인:**
```bash
# GitHub에서 워크플로 로그 확인
# → 각 레포 → Actions → 최근 실행 → 실패한 job → 로그 클릭

# 일반적인 오류:
# 1. "AccessDenied" → AWS 권한 부족
# 2. "InvalidParameterException" → ECR_REPOSITORY 이름 오류
# 3. "NoCredentialProviders" → AWS_ACCESS_KEY_ID/SECRET_ACCESS_KEY 누락
```

---

## Phase 6. ArgoCD 설치 및 설정

### 6-1. ArgoCD 네임스페이스 및 설치

```bash
# ArgoCD 네임스페이스 생성
kubectl create namespace argocd

# ArgoCD 설치 (Helm 또는 kubectl)
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Pod 대기 (1~2분)
kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=argocd-server -n argocd --timeout=300s
```

### 6-2. ArgoCD Admin 초기 암호 확인

```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
```

### 6-3. ArgoCD 접근 (로컬에서)

```bash
# Port forward
kubectl port-forward svc/argocd-server -n argocd 8080:443

# 브라우저: https://localhost:8080
# 사용자명: admin
# 비밀번호: [위에서 확인한 값]
```

### 6-4. GitHub 레포 연결

ArgoCD 콘솔에서:

1. **Settings → Repositories → Connect Repo**
2. 연결 방식: HTTPS
3. Repository URL: `https://github.com/YOUR_ORG/infra-medicare.git`
4. **Connect**

(개인 레포인 경우 GitHub PAT 필요)

### 6-5. ArgoCD Application 생성

```bash
kubectl apply -f k8s/argocd/application.yaml
```

`application.yaml` 예시:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: medical-service
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/YOUR_ORG/infra-medicare.git
    targetRevision: main
    path: k8s/overlays/prod
  destination:
    server: https://kubernetes.default.svc
    namespace: default
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

---

## Phase 7. 이미지 수동 업데이트 및 배포

### 7-1. CI 빌드 후 ECR 이미지 확인

GitHub Actions이 자동으로 빌드 후 ECR에 푸시하면, 다음으로 이미지 태그를 확인합니다:

```bash
aws ecr describe-images \
  --repository-name medical-service-frontend \
  --region ap-northeast-2 \
  --query 'imageDetails[*].[imageTags[0],imagePushedAt]' \
  --output table
```

### 7-2. 이미지 태그 수동 업데이트


`kustomization.yaml` 이미지 태그 자동화 (PR 기반)

CI가 각 서비스의 이미지를 빌드·푸시하면, 서비스별 GitHub Actions 워크플로가 자동으로
`medical-service-infra/k8s/overlays/prod/kustomization.yaml`의 해당 서비스 이미지(`frontend`, `backend`, `ai`) `newName`과 `newTag`를
업데이트한 브랜치를 생성하고 해당 변경을 포함한 Pull Request를 자동으로 만듭니다.

자동화 동작 요약:

- 빌드 성공 → 이미지 푸시 → 워크플로가 `kustomization.yaml`을 업데이트한 브랜치 생성 → PR 생성
- PR이 머지되면 ArgoCD가 변경을 감지하고 배포를 수행합니다.

장점 및 주의사항:

- 브랜치 보호가 활성화된 리포지토리에서도 동작합니다(자동 푸시 권한 불필요).  
- PR을 통해 변경 내역 리뷰·CI를 통과한 후 배포하도록 워크플로를 설계했습니다.  
- 자동 업데이트는 빌드된 이미지가 레지스트리에 정상적으로 푸시된 이후에 동작합니다.



### 7-3. ArgoCD 동기화 확인

ArgoCD 콘솔 또는 CLI에서 동기화 상태 확인:

```bash
kubectl get application medical-service -n argocd
```

**상태 확인 (예상 출력):**
```
NAME              SYNC STATUS   HEALTH STATUS   
medical-service   Synced        Healthy
```

배포된 Pod 확인:

```bash
kubectl get pods
kubectl describe pod [POD_NAME]
kubectl logs [POD_NAME]
```

---

## 트러블슈팅

### EKS 노드 상태 확인

```bash
kubectl get nodes -o wide
kubectl describe node [NODE_NAME]
```

### ECR 로그인 실패

```bash
aws ecr get-login-password --region ap-northeast-2 | \
  docker login --username AWS --password-stdin 123456789012.dkr.ecr.ap-northeast-2.amazonaws.com
```

### RDS 연결 테스트

```bash
# 로컬에서 RDS에 연결 (mysql 클라이언트 필요)
mysql -h medical-service-aurora.xxxxx.ap-northeast-2.rds.amazonaws.com \
      -u admin -p medicalservicedb

# 또는 kubectl에서 테스트 Pod 생성
kubectl run mysql-test --image=mysql:8.0 --rm -it --restart=Never -- \
  mysql -h medical-service-aurora.xxxxx.ap-northeast-2.rds.amazonaws.com \
        -u admin -p medicalservicedb
```

### ArgoCD 동기화 실패

```bash
# ArgoCD 로그 확인
kubectl logs -n argocd deployment/argocd-application-controller

# Application 상태 상세 확인
kubectl describe application medical-service -n argocd
```

### Terraform 상태 조회

```bash
cd medical-service-infra/terraform

# 현재 상태 확인
terraform show

# 특정 리소스만 조회
terraform state show aws_eks_cluster.eks
```

---

## 정리 (삭제)

> ⚠️ **주의**: 아래 명령어는 모든 AWS 리소스를 삭제합니다. 신중하게 사용하세요.

```bash
cd medical-service-infra/terraform

# 생성된 리소스 전체 삭제 (EKS, RDS, ECR, VPC 등)
terraform destroy

# S3 버킷 비우기 (상태 파일 백업 필요)
aws s3 rm s3://YOUR_BUCKET_NAME --recursive

# S3 버킷 삭제
aws s3api delete-bucket --bucket YOUR_BUCKET_NAME

# DynamoDB 테이블 삭제
aws dynamodb delete-table --table-name medical-service-tf-lock
```

---

## 참고 자료

- [AWS EKS 공식 문서](https://docs.aws.amazon.com/eks/)
- [Terraform AWS Provider](https://registry.terraform.io/providers/hashicorp/aws/latest/docs)
- [ArgoCD 공식 문서](https://argo-cd.readthedocs.io/)
- [Kubernetes 공식 문서](https://kubernetes.io/docs/)

---

**Last Updated**: May 2026  
**Project**: Medical Service Infrastructure
