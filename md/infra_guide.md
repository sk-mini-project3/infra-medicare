# 의료 서비스 인프라 기술 가이드

## 목차

1. [아키텍처 개요](#아키텍처-개요)
2. [프로젝트 구조](#프로젝트-구조)
3. [Terraform 상세 가이드](#terraform-상세-가이드)
4. [GitHub Actions CI/CD](#github-actionscici-d)
5. [Kubernetes & ArgoCD](#kubernetes--argocd)
6. [환경 변수 및 설정 관리](#환경-변수-및-설정-관리)
7. [로컬 개발 환경](#로컬-개발-환경)
8. [이미지 태그 자동 업데이트 (PR 기반)](#이미지-태그-자동-업데이트-pr-기반)
9. [모니터링 및 로깅](#모니터링-및-로깅)
10. [보안 체크리스트](#보안-체크리스트)
11. [트러블슈팅](#트러블슈팅)
12. [개발순서](#개발순서)

---

## 아키텍처 개요

### 전체 시스템 다이어그램

```
┌─────────────────────────────────────────────────────────────────────┐
│                         GitHub (Git & Actions)                      │
│  ┌──────────────┐ ┌──────────────┐ ┌──────────┐ ┌─────────────┐    │
│  │  frontend    │ │   backend    │ │ ai-model │ │ infra (IaC) │    │
│  │  (React)     │ │  (Spring)    │ │(FastAPI) │ │ (Terraform) │    │
│  └──────┬───────┘ └──────┬───────┘ └────┬─────┘ └──────┬──────┘    │
│         │                │              │               │           │
│         └─── GitHub Actions CI/CD (자동 빌드/테스트) ────┘           │
└─────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
                        ┌─────────────────────┐
                        │   AWS (ap-ne-2)     │
                        ├─────────────────────┤
                        │  ┌───────────────┐  │
                        │  │   ECR (이미지) │  │ ◄── CI에서 푸시
                        │  └───────┬───────┘  │
                        │          │          │
                        │    ┌─────▼──────┐   │
                        │    │ EKS Cluster│   │ ◄── GitOps (ArgoCD)
                        │    │ ┌────────┐ │   │
                        │    │ │ Pods   │ │   │
                        │    │ └────────┘ │   │
                        │    └──────┬─────┘   │
                        │           │         │
                        │    ┌──────▼──────┐  │
                        │    │ Aurora MySQL│  │
                        │    │ RDS Cluster │  │
                        │    └─────────────┘  │
                        └─────────────────────┘
```

### 주요 특징

- **멀티 레포**: 각 서비스별 독립적인 Git 레포 → 팀 간 자율성
- **IaC (Infrastructure as Code)**: Terraform으로 모든 AWS 리소스 관리
- **GitOps**: ArgoCD가 Git 상태를 감시하고 클러스터 자동 동기화
- **자동 배포**: 코드 푸시 → CI 빌드 → ECR 푸시 → `kustomization.yaml` 자동 업데이트 PR 생성 → 머지 후 ArgoCD 감지 → 배포
- **PR 기반 GitOps**: 이미지 태그 변경 이력을 PR로 리뷰하고 머지 후 반영 (브랜치 보호와 궁합이 좋음)

---

## 프로젝트 구조

### 로컬 폴더 구조

```
medical-service-infra/
├── md/
│   ├── DEPLOY.md             # ← Phase별 배포 단계별 가이드
│   └── infra_guide.md        # ← 이 파일
├── terraform/
│   ├── provider.tf          # AWS 프로바이더 & backend 주석
│   ├── backend.tf           # 상태 파일 backend 설명
│   ├── versions.tf          # Terraform 버전 요구사항
│   ├── variables.tf         # 변수 정의
│   ├── vpc.tf               # VPC, 서브넷, IGW, NAT GW
│   ├── eks.tf               # EKS 클러스터, 노드 그룹, IAM
│   ├── rds.tf               # Aurora MySQL
│   ├── ecr.tf               # ECR 리포지토리
│   ├── outputs.tf           # 출력값
│   ├── terraform.tfvars.example  # 변수값 예시
│   └── terraform.tfvars     # 변수값 (로컬, Git 제외)
│
├── k8s/
│   ├── base/                # Kubernetes 기본 매니페스트
│   │   ├── namespace.yaml
│   │   ├── frontend-deployment.yaml
│   │   ├── backend-deployment.yaml
│   │   ├── ai-deployment.yaml
│   │   ├── *-service.yaml
│   │   └── kustomization.yaml
│   │
│   └── overlays/
│       └── prod/            # 프로덕션 오버레이
│           └── kustomization.yaml  # ← 이 파일에서 이미지 태그 관리
│
├── argocd/
│   └── application.yaml     # ArgoCD Application
│
└── scripts/
    └── deploy.sh
```

### 4개 GitHub 레포 구조

#### 1. `medical-service-frontend`
```
medical-service-frontend/
├── Dockerfile
├── nginx.conf
├── package.json
├── .github/workflows/
│   └── frontend-ci-cd.yml
├── src/
└── public/
```

#### 2. `medical-service-backend`
```
medical-service-backend/
├── Dockerfile
├── pom.xml (또는 build.gradle)
├── .github/workflows/
│   └── backend-ci-cd.yml
├── src/main/java/
└── src/main/resources/
```

#### 3. `ai-medicare`
```
ai-medicare/
├── Dockerfile
├── requirements.txt
├── .github/workflows/
│   └── ai-ci-cd.yml
├── app/
│   └── main.py
└── tests/
```

#### 4. `medical-service-infra` (이 폴더)
- Terraform 파일들
- k8s 매니페스트 (base & overlays)
- ArgoCD 설정

---

## Terraform 상세 가이드

### 1. 파일별 역할

#### `provider.tf`
AWS 프로바이더 및 기본 태그:

```hcl
provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "Terraform"
    }
  }
}
```

#### `backend.tf`
Terraform 상태 백엔드 설정 (S3 + DynamoDB):

```hcl
# ⚠️ backend 블록 내부에서는 변수 사용 불가!
# 'terraform init' 시 -backend-config 플래그 사용:
#
# terraform init \
#   -backend-config="bucket=..." \
#   -backend-config="key=..." \
#   ...
```

#### `variables.tf`
입력 변수 정의:

```hcl
variable "aws_region" {
  type    = string
  default = "ap-northeast-2"
}

variable "project_name" {
  type    = string
  default = "medical-service"
}

variable "db_password" {
  type      = string
  sensitive = true  # 출력 마스킹
}
# ... 기타 변수
```

#### `vpc.tf`
VPC, 서브넷, IGW, NAT GW, 라우팅 테이블

#### `eks.tf`
EKS 클러스터, 노드 그룹, IAM 역할

#### `rds.tf`
Aurora MySQL 클러스터 (프라이빗 서브넷)

#### `ecr.tf`
ECR 리포지토리 (frontend, backend, ai × 3개)

#### `outputs.tf`
중요한 리소스 정보 출력 (ECR URI, EKS 엔드포인트, RDS 엔드포인트 등)

### 2. Terraform 워크플로

#### 초기 실행 (최초 1회)

```bash
cd medical-service-infra/terraform

# 1. Backend 초기화
terraform init \
  -backend-config="bucket=medical-service-tf-state" \
  -backend-config="key=medical-service/terraform.tfstate" \
  -backend-config="region=ap-northeast-2" \
  -backend-config="dynamodb_table=medical-service-tf-lock"

# 2. 변수 파일 준비
cp terraform.tfvars.example terraform.tfvars
# terraform.tfvars 에서 db_password 변경

# 3. Plan & Validate
terraform fmt -recursive
terraform validate
terraform plan

# 4. Apply
terraform apply
```

#### 이후 변경

```bash
terraform plan
terraform apply
terraform destroy  # 삭제 시
```

---

## GitHub Actions CI/CD

### CI/CD 흐름

각 서비스 레포에서:

1. **Checkout** → 코드 클론
2. **빌드** → 언어별 빌드 (npm, gradle, pip 등)
3. **Docker 빌드** → Dockerfile 기반 이미지 생성
4. **ECR 로그인** → AWS 인증
5. **Docker 푸시** → ECR에 이미지 푸시

### 워크플로 파일 위치

- `medical-service-frontend/.github/workflows/frontend-ci-cd.yml`
- `medical-service-backend/.github/workflows/backend-ci-cd.yml`
- `ai-medicare/.github/workflows/ai-ci-cd.yml`

### 워크플로 예시

**Frontend (React):**
```yaml
name: Build and Push to ECR

on:
  push:
    branches: [ main ]

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      
      - name: Set up Node
        uses: actions/setup-node@v4
        with:
          node-version: '18'
      
      - name: Install & Build
        run: |
          npm install
          npm run build
      
      - name: Configure AWS credentials
        uses: aws-actions/configure-aws-credentials@v4
        with:
          aws-access-key-id: ${{ secrets.AWS_ACCESS_KEY_ID }}
          aws-secret-access-key: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
          aws-region: ap-northeast-2
      
      - name: Login to ECR
        uses: aws-actions/amazon-ecr-login@v2
      
      - name: Push image
        env:
          ECR_REGISTRY: ${{ steps.login-ecr.outputs.registry }}
          IMAGE_TAG: ${{ github.sha }}
        run: |
          docker build -t $ECR_REGISTRY/${{ secrets.ECR_REPOSITORY }}:$IMAGE_TAG .
          docker push $ECR_REGISTRY/${{ secrets.ECR_REPOSITORY }}:$IMAGE_TAG
```

**Backend (Spring Boot):**
```yaml
name: Build and Push to ECR

on:
  push:
    branches: [ main ]

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      
      - name: Set up JDK
        uses: actions/setup-java@v4
        with:
          java-version: '17'
          distribution: 'temurin'
      
      - name: Build with Gradle
        run: ./gradlew bootJar
      
      - name: Configure AWS credentials
        uses: aws-actions/configure-aws-credentials@v4
        with:
          aws-access-key-id: ${{ secrets.AWS_ACCESS_KEY_ID }}
          aws-secret-access-key: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
          aws-region: ap-northeast-2
      
      - name: Login to ECR
        uses: aws-actions/amazon-ecr-login@v2
      
      - name: Push image
        env:
          ECR_REGISTRY: ${{ steps.login-ecr.outputs.registry }}
          IMAGE_TAG: ${{ github.sha }}
        run: |
          docker build -t $ECR_REGISTRY/${{ secrets.ECR_REPOSITORY }}:$IMAGE_TAG .
          docker push $ECR_REGISTRY/${{ secrets.ECR_REPOSITORY }}:$IMAGE_TAG
```

**AI (FastAPI + Python):**
```yaml
name: Build and Push to ECR

on:
  push:
    branches: [ main ]

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      
      - name: Set up Python
        uses: actions/setup-python@v4
        with:
          python-version: '3.11'
      
      - name: Install dependencies
        run: |
          python -m pip install --upgrade pip
          pip install -r requirements.txt
      
      - name: Configure AWS credentials
        uses: aws-actions/configure-aws-credentials@v4
        with:
          aws-access-key-id: ${{ secrets.AWS_ACCESS_KEY_ID }}
          aws-secret-access-key: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
          aws-region: ap-northeast-2
      
      - name: Login to ECR
        uses: aws-actions/amazon-ecr-login@v2
      
      - name: Push image
        env:
          ECR_REGISTRY: ${{ steps.login-ecr.outputs.registry }}
          IMAGE_TAG: ${{ github.sha }}
        run: |
          docker build -t $ECR_REGISTRY/${{ secrets.ECR_REPOSITORY }}:$IMAGE_TAG .
          docker push $ECR_REGISTRY/${{ secrets.ECR_REPOSITORY }}:$IMAGE_TAG
```

### GitHub Secrets 설정

각 레포의 **Settings → Secrets and variables → Actions**:

```
AWS_ACCESS_KEY_ID              = xxxxxxxxxxxxxxxxxxxx
AWS_SECRET_ACCESS_KEY          = xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
ECR_REPOSITORY                 = medical-service-frontend (또는 backend, ai)
```

---

## Kubernetes & ArgoCD

### 1. k8s 매니페스트 구조 (Kustomize)

#### Base: `k8s/base/kustomization.yaml`

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: default

resources:
  - namespace.yaml
  - frontend-deployment.yaml
  - frontend-service.yaml
  - backend-deployment.yaml
  - backend-service.yaml
  - ai-deployment.yaml
  - ai-service.yaml

images:
  - name: medical-service-frontend
    newName: medical-service-frontend
  - name: medical-service-backend
    newName: medical-service-backend
  - name: medical-service-ai
    newName: medical-service-ai
```

#### Prod Overlay: `k8s/overlays/prod/kustomization.yaml`

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

bases:
  - ../../base

# ← 여기서 실제 ECR URI와 이미지 태그 지정 (수동으로 관리)
images:
  - name: medical-service-frontend
    newName: 123456789012.dkr.ecr.ap-northeast-2.amazonaws.com/medical-service-frontend
    newTag: sha-a1b2c3d4

  - name: medical-service-backend
    newName: 123456789012.dkr.ecr.ap-northeast-2.amazonaws.com/medical-service-backend
    newTag: sha-e5f6g7h8

  - name: medical-service-ai
    newName: 123456789012.dkr.ecr.ap-northeast-2.amazonaws.com/medical-service-ai
    newTag: sha-i9j0k1l2
```

### 2. ArgoCD Application: `argocd/application.yaml`

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: medical-service
  namespace: argocd

spec:
  project: default

  source:
    repoURL: https://github.com/YOUR_ORG/medical-service-infra.git
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

### 3. Deployment 예시

**Frontend:**
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: frontend
spec:
  replicas: 2
  selector:
    matchLabels:
      app: frontend
  template:
    metadata:
      labels:
        app: frontend
    spec:
      containers:
      - name: frontend
        image: medical-service-frontend
        ports:
        - containerPort: 80
        resources:
          requests:
            memory: "128Mi"
            cpu: "100m"
          limits:
            memory: "256Mi"
            cpu: "500m"
        livenessProbe:
          httpGet:
            path: /
            port: 80
          initialDelaySeconds: 10
          periodSeconds: 10
        readinessProbe:
          httpGet:
            path: /
            port: 80
          initialDelaySeconds: 5
          periodSeconds: 5
```

**Backend:**
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: backend
spec:
  replicas: 2
  selector:
    matchLabels:
      app: backend
  template:
    metadata:
      labels:
        app: backend
    spec:
      containers:
      - name: backend
        image: medical-service-backend
        ports:
        - containerPort: 8080
        env:
        - name: DATABASE_URL
          value: "jdbc:mysql://aurora-endpoint:3306/medicalservicedb"
        - name: DATABASE_USER
          value: "admin"
        - name: DATABASE_PASSWORD
          valueFrom:
            secretKeyRef:
              name: db-credentials
              key: password
        - name: AI_BASE_URL
          value: "http://ai:8001"
        resources:
          requests:
            memory: "512Mi"
            cpu: "250m"
          limits:
            memory: "1Gi"
            cpu: "1000m"
        livenessProbe:
          httpGet:
            path: /health
            port: 8080
          initialDelaySeconds: 15
        readinessProbe:
          httpGet:
            path: /health/ready
            port: 8080
          initialDelaySeconds: 10
```

**AI:**
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ai
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ai
  template:
    metadata:
      labels:
        app: ai
    spec:
      containers:
      - name: ai
        image: medical-service-ai
        ports:
        - containerPort: 8001
        env:
        - name: LOG_LEVEL
          value: "INFO"
        resources:
          requests:
            memory: "256Mi"
            cpu: "100m"
          limits:
            memory: "1Gi"
            cpu: "1000m"
        livenessProbe:
          httpGet:
            path: /health
            port: 8001
          initialDelaySeconds: 20
        readinessProbe:
          httpGet:
            path: /health/ready
            port: 8001
          initialDelaySeconds: 10
```

---

## 환경 변수 및 설정 관리

### ConfigMap

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: app-config
  namespace: default

data:
  LOG_LEVEL: "DEBUG"
  AI_BASE_URL: "http://ai:8001"
  BACKEND_API_URL: "http://backend:8080"
```

### Secret

```bash
kubectl create secret generic db-credentials \
  --from-literal=password="YourPassword123!" \
  --from-literal=username="admin"
```

---

## 로컬 개발 환경

### Docker Compose

```yaml
version: '3.8'

services:
  frontend:
    build:
      context: ../medical-service-frontend
      dockerfile: Dockerfile
    ports:
      - "8080:80"
    environment:
      - REACT_APP_API_URL=http://localhost:3000
    depends_on:
      - backend

  backend:
    build:
      context: ../medical-service-backend
      dockerfile: Dockerfile
    ports:
      - "3000:8080"
    environment:
      - DATABASE_URL=jdbc:mysql://mysql:3306/medicalservicedb
      - DATABASE_USER=root
      - DATABASE_PASSWORD=rootpassword
      - AI_BASE_URL=http://ai:8001
    depends_on:
      - mysql
      - ai
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8080/health"]
      interval: 10s
      timeout: 5s
      retries: 5

  ai:
    build:
      context: ../ai-medicare
      dockerfile: Dockerfile
    ports:
      - "8001:8001"
    environment:
      - LOG_LEVEL=DEBUG
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8001/health"]
      interval: 10s
      timeout: 5s
      retries: 5

  mysql:
    image: mysql:8.0
    ports:
      - "3306:3306"
    environment:
      - MYSQL_ROOT_PASSWORD=rootpassword
      - MYSQL_DATABASE=medicalservicedb
    volumes:
      - mysql_data:/var/lib/mysql

volumes:
  mysql_data:
```

**실행:**
```bash
docker-compose up -d
docker-compose logs -f backend
docker-compose down
```

---

## 이미지 태그 자동 업데이트 (PR 기반)

### 절차 개요

1. 서비스 CI가 이미지를 빌드해 ECR에 푸시 (자동)
2. 워크플로가 `k8s/overlays/prod/kustomization.yaml`의 `images[].newName/newTag` 갱신 (자동)
3. 변경 내용을 `ci/update-<service>-<sha>` 브랜치로 만들고 PR 생성 (자동)
4. PR 머지 후 ArgoCD가 Git 변경을 감지해 자동 배포 (자동)

### Step 1: ECR 이미지 확인

```bash
aws ecr describe-images \
  --repository-name medical-service-frontend \
  --region ap-northeast-2 \
  --query 'imageDetails[*].[imageTags,imagePushedAt]' \
  --output table
```

**출력 예시:**
```
imageTags       imagePushedAt
───────────────────────────────
['sha-a1b2c3d4']   2026-05-07 10:30:00+00:00
```

### Step 2: 자동 생성된 PR 확인 및 머지

서비스 레포 Actions 실행이 끝나면 자동으로 생성된 PR을 확인합니다.

- 브랜치 예시: `ci/update-frontend-<github_sha>`
- 커밋 메시지 예시: `ci: bump frontend image to <github_sha> [skip ci]`
- 변경 파일: `k8s/overlays/prod/kustomization.yaml`

리뷰 후 PR을 머지하면 배포가 진행됩니다.

### Step 3: ArgoCD 동기화 확인

```bash
# ArgoCD가 자동으로 감지해 배포
kubectl get application medical-service -n argocd

# Pod 롤링 업데이트 확인
kubectl get pods
kubectl logs deployment/frontend
```

**예상 상태:**
```
NAME              SYNC STATUS   HEALTH STATUS
medical-service   Synced        Healthy
```

### 참고: 수동 업데이트가 필요한 경우

아래 경우에는 임시로 수동 업데이트를 사용할 수 있습니다.

- 서비스/인프라 레포 분리로 인해 CI가 인프라 파일을 직접 갱신하지 못할 때
- PR 자동 생성 권한(`contents: write`, `pull-requests: write`)이 제한될 때
- 긴급 롤백/핫픽스로 특정 태그를 즉시 고정해야 할 때

---
### 남은 개발순서
1️⃣ POST_CLONE_SETUP.md
   ├─ Phase 1: 각 서비스 Docker 빌드 테스트 (AI, Backend, Frontend)
   ├─ Phase 2: Docker Compose 통합 테스트
   └─ Phase 3: 배포 설정 파일 검토 & 기록

2️⃣ 모두 완료 후 → EKS 설치 준비

3️⃣ AFTER_EKS.md 참고
   ├─ Step 1: EKS 클러스터 생성 (terraform apply)
   ├─ Step 2: kubeconfig 연결
   ├─ Step 3: ArgoCD 설치
   └─ Step 4~8: 배포 완료

## 모니터링 및 로깅

### Pod 로그 조회

```bash
# 실시간 로그
kubectl logs -f deployment/backend

# 여러 Pod 로그
kubectl logs -f -l app=backend

# 이전 Pod 로그 (크래시 후)
kubectl logs [POD_NAME] --previous
```

### CloudWatch 로그

```bash
# Aurora 로그
aws logs tail /aws/rds/cluster/medical-service-aurora --follow

# 로그 그룹 목록
aws logs describe-log-groups
```

---

## 보안 체크리스트

- [ ] `db_password` 등 민감 정보는 `.gitignore` 포함
- [ ] RDS는 프라이빗 서브넷에 배치
- [ ] ECR 이미지 스캔 활성화
- [ ] RBAC 정책 설정
- [ ] Secret은 암호화되어 저장
- [ ] GitHub PAT는 최소 권한 범위
- [ ] ArgoCD 초기 password 변경

---

## 트러블슈팅

### EKS 노드 연결 불가

```bash
kubectl cluster-info
kubectl describe node [NODE_NAME]
```

### Pod CrashLoopBackOff

```bash
kubectl describe pod [POD_NAME]
kubectl logs [POD_NAME]
kubectl logs [POD_NAME] --previous
```

### ArgoCD 동기화 실패

```bash
kubectl describe application medical-service -n argocd
kubectl logs -n argocd deployment/argocd-application-controller
```

### RDS 연결 테스트

```bash
# 테스트 Pod 생성
kubectl run mysql-test --image=mysql:8.0 --rm -it --restart=Never -- \
  mysql -h [RDS_ENDPOINT] -u admin -p [DB_NAME]
```

---

**Last Updated**: May 2026  
**Version**: 2.0  
**Project**: Medical Service Infrastructure
