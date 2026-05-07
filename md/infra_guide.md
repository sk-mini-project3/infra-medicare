# 인프라 실행 가이드

이 문서는 AWS 계정을 아직 받지 못한 상태에서 시작해, 계정을 받은 뒤 무엇부터 해야 하는지, GitHub Actions로 이미지를 ECR에 올리고, Terraform으로 EKS와 Aurora(MySQL Compatible)를 만들고, Argo CD로 배포하기까지의 전 과정을 한 파일로 정리한 실행 매뉴얼입니다.

이 문서만 따라가면 아래 흐름으로 진행할 수 있게 작성했습니다.

1. 로컬 개발 환경 준비
2. GitHub 레포 4개 생성
3. AWS 계정 수령 후 IAM/CLI 설정
4. Terraform state backend(S3 + DynamoDB) 생성
5. Terraform 1차 실행으로 ECR/VPC/Aurora 생성, 2차 실행으로 EKS 생성
6. GitHub Secrets 등록 후 프론트/백/AI CI 활성화
7. Argo CD 설치 전 클러스터/노드 상태 확인
8. Argo CD 설치 및 `application.yaml` 연결
9. k8s 매니페스트의 이미지 태그 갱신 후 Argo CD로 배포

## 0. 최종 목표 구조

- `frontend-medicare`: 프론트엔드 코드, Dockerfile, GitHub Actions
- `backend-medicare`: 백엔드 코드, Dockerfile, GitHub Actions
- `ai-medicare`: FastAPI + scikit-learn AI 탐지 서비스, Dockerfile, GitHub Actions
- `infra-medicare`: Terraform, k8s 매니페스트, Argo CD 설정

## 1. AWS 계정 받기 전 미리 준비할 것

AWS 계정이 없어도 아래 작업은 먼저 할 수 있습니다.

### 1-1. 로컬 도구 설치

- `Docker`
- `AWS CLI`
- `Terraform`
- `kubectl`
- `Helm`

설치 확인 예시:

```bash
docker --version
aws --version
terraform -version
kubectl version --client
```

### 1-2. GitHub 레포 이름 확정

아래 4개 레포를 만든다고 가정합니다.

- `frontend-medicare`
- `backend-medicare`
- `ai-medicare`
- `infra-medicare`

### 1-3. 각 레포 기본 구조 준비

프론트 레포 예시:

```text
frontend-medicare/
  src/
  public/
  package.json
  Dockerfile
  nginx.conf
  .github/workflows/frontend-ci-cd.yml
```

백엔드 레포 예시:

```text
backend-medicare/
  src/
  package.json
  Dockerfile
  .github/workflows/backend-ci-cd.yml
```

인프라 레포 예시:

```text
infra-medicare/
  terraform/
  k8s/
    base/
    overlays/
  argocd/
  .github/workflows/
```

AI 레포 예시:

```text
ai-medicare/
  app/
  models/
  Dockerfile
  requirements.txt
  .github/workflows/ai-ci-cd.yml
```

### 1-4. 로컬 Docker 실행 확인

```bash
docker compose up --build
docker build -t medical-frontend:local .
docker run -p 8080:80 medical-frontend:local
docker build -t medical-backend:local .
docker run -p 3000:3000 medical-backend:local
```

## 2. AWS 계정을 받으면 가장 먼저 할 일

AWS 계정을 받는 순간부터는 아래 순서로 진행합니다.

### 2-1. AWS 로그인 방식 결정

둘 중 하나를 선택합니다.

- 방법 A: IAM Access Key / Secret Key 사용
- 방법 B: AWS SSO 또는 GitHub OIDC 사용

가장 쉬운 시작은 IAM Access Key 방식입니다. 나중에 OIDC로 바꿔도 됩니다.

### 2-2. 로컬 AWS CLI 연결

```bash
aws configure
```

입력할 값:

- AWS Access Key ID
- AWS Secret Access Key
- Default region name: `ap-northeast-2`
- Default output format: `json`

확인 명령:

```bash
aws sts get-caller-identity
```

### 2-3. 먼저 만들어야 하는 것

Terraform을 실행하기 전에 **수동으로 먼저 만들어야 하는 자원**은 다음입니다.

- **S3 bucket** (Terraform state 저장용)
- **DynamoDB table** (Terraform lock용)

그 다음 Terraform으로 만들 자원은 다음입니다.

- ECR repositories (frontend, backend, ai)
- VPC / Subnets / Internet Gateway
- Aurora(MySQL Compatible)
- EKS Cluster + Node Group는 나중에 별도 적용

CI는 ECR이 준비된 뒤에 이미지를 push할 수 있으므로, Terraform 적용이 완료된 뒤에 GitHub Secrets와 CI를 설정합니다.

## 3. Terraform 2단계 실행: 먼저 ECR/VPC/RDS, 그다음 EKS

시작 전에 프론트/백/AI가 로컬에서 `docker build` 되는지 한 번 확인해두면, 인프라 문제와 애플리케이션 이미지 문제를 분리해서 디버깅하기 쉽습니다(권장, 필수 아님).

### 3-1. state backend 생성

Terraform state를 저장할 S3와 락을 위한 DynamoDB를 만듭니다.

```bash
aws s3 mb s3://mini3-tfstate-prod --region ap-northeast-2
aws dynamodb create-table \
  --table-name terraform-locks \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region ap-northeast-2
```

### 3-2. Terraform 변수 파일 준비

`infra-medicare/terraform/terraform.tfvars.example`를 복사해서 로컬 파일을 만듭니다.

Windows PowerShell 예시:

```powershell
cd infra-medicare/terraform
Copy-Item terraform.tfvars.example terraform.tfvars
```

Linux/macOS라면:

```bash
cp terraform.tfvars.example terraform.tfvars
```

`terraform.tfvars` 편집 예시:

```hcl
aws_region             = "ap-northeast-2"
project_name           = "medical-service"
vpc_cidr               = "10.0.0.0/16"
public_subnet_cidrs    = ["10.0.1.0/24", "10.0.2.0/24"]
private_subnet_cidrs   = ["10.0.11.0/24", "10.0.12.0/24"]
db_name                = "medicalservicedb"
db_username            = "admin"
db_password            = "YOUR_SECURE_PASSWORD_HERE"
db_instance_class      = "db.t3.medium"
eks_cluster_version    = "1.27"
eks_node_group_size    = 2
ecr_frontend_name      = "medical-service-frontend"
ecr_backend_name       = "medical-service-backend"
ecr_ai_name            = "medical-service-ai"
```

### 3-3. Terraform 실행 (한 번에)

아래처럼 두 번 나눠서 적용합니다.

**Step 1: terraform init with backend config**

```bash
cd infra-medicare/terraform

# 이미 'mini3-tfstate-prod' S3 버킷과 'terraform-locks' DynamoDB 테이블을 만들었다면:
terraform init \
  -backend-config="bucket=mini3-tfstate-prod" \
  -backend-config="key=medical-service/terraform.tfstate" \
  -backend-config="region=ap-northeast-2" \
  -backend-config="dynamodb_table=terraform-locks" \
  -backend-config="encrypt=true"

terraform init -backend-config="bucket=mini3-tfstate-prod" -backend-config="key=medical-service/terraform.tfstate" -backend-config="region=ap-northeast-2" -backend-config="dynamodb_table=terraform-locks" -backend-config="encrypt=true"
```

버킷 이름이 다르면 위 명령에서 `bucket=your-bucket-name`으로 수정합니다.

**Step 2: Format, validate, plan**

```bash
terraform fmt -recursive
terraform validate
terraform plan -out tfplan
```

**Step 3: First apply only non-EKS resources**

```bash
terraform apply -target=aws_ecr_repository.frontend \
  -target=aws_ecr_repository.backend \
  -target=aws_ecr_repository.ai \
  -target=aws_vpc.main \
  -target=aws_internet_gateway.gw \
  -target=aws_subnet.public \
  -target=aws_subnet.private \
  -target=aws_route_table.public \
  -target=aws_route_table_association.public_assoc \
  -target=aws_security_group.rds \
  -target=aws_db_subnet_group.default \
  -target=aws_rds_cluster.aurora \
  -target=aws_rds_cluster_instance.aurora_primary
```

**Step 4: 결과 확인**

```bash
terraform output
```

### 3-4. 적용 직후 확인할 값

`terraform output`에서 첫 단계 기준으로 아래 값들을 확인합니다. 이 값들은 GitHub Secrets와 k8s 매니페스트에서 필요합니다.

- `ecr_frontend_repository` = ECR frontend 저장소 URL
- `ecr_backend_repository` = ECR backend 저장소 URL
- `ecr_ai_repository` = ECR AI 저장소 URL
- `rds_address` = Aurora writer endpoint 호스트명 (예: `medical-service-aurora.cluster-xxxx.ap-northeast-2.rds.amazonaws.com`)
- `rds_endpoint` = Aurora 호스트:포트 (예: `medical-service-aurora.cluster-xxxx.ap-northeast-2.rds.amazonaws.com:3306`)
- `db_name` = 데이터베이스 이름

EKS 관련 출력값(`eks_cluster_name`, `eks_cluster_endpoint`)은 두 번째 적용 후 확인합니다.

### 3-5. EKS는 나중에 별도 적용

ECR/VPC/RDS가 준비된 뒤에 EKS만 추가로 만듭니다.

```bash
terraform apply
```

이 두 번째 적용에서는 `eks.tf`에 있는 EKS Cluster / Node Group만 생성됩니다.

### 3-6. 두 단계로 나눌 때 참고

- 리소스가 많아 `terraform apply` 시간이 길어질 수 있습니다.
- 중간에 실패하면 이미 생성된 리소스는 남을 수 있으므로, 에러 수정 후 `terraform plan`/`apply`를 다시 실행해 상태를 수렴시킵니다.
- `-target`은 첫 단계만 만들 때 쓰는 임시 방식입니다. 첫 단계가 끝나면 두 번째 단계에서는 `terraform apply`만 실행해서 전체 상태를 맞춥니다.

## 4. GitHub Secrets 등록

GitHub에서 각 레포의 `Settings > Secrets and variables > Actions`에 등록합니다.

### 4-1. `frontend-medicare` 레포 secrets

- `AWS_REGION` = `ap-northeast-2`
- `AWS_ACCOUNT_ID` = `<12자리 AWS 계정 ID>`
- `AWS_ACCESS_KEY_ID` = `<IAM access key>`
- `AWS_SECRET_ACCESS_KEY` = `<IAM secret key>`
- `ECR_FRONTEND_REPOSITORY` = `frontend-medicare`

전체 ECR URI를 넣고 싶으면 아래 형태로 저장해도 됩니다.

- `ECR_FRONTEND_URI` = `123456789012.dkr.ecr.ap-northeast-2.amazonaws.com/frontend-medicare`

### 4-2. `backend-medicare` 레포 secrets

- `AWS_REGION` = `ap-northeast-2`
- `AWS_ACCOUNT_ID` = `<12자리 AWS 계정 ID>`
- `AWS_ACCESS_KEY_ID` = `<IAM access key>`
- `AWS_SECRET_ACCESS_KEY` = `<IAM secret key>`
- `ECR_BACKEND_REPOSITORY` = `backend-medicare`

전체 ECR URI를 넣고 싶으면 아래 형태로 저장해도 됩니다.

- `ECR_BACKEND_URI` = `123456789012.dkr.ecr.ap-northeast-2.amazonaws.com/backend-medicare`

### 4-3. `infra-medicare` 레포 secrets

Terraform이나 Argo CD 관련 작업이 있으면 아래를 추가합니다.

- `AWS_REGION` = `ap-northeast-2`
- `AWS_ACCOUNT_ID` = `<12자리 AWS 계정 ID>`
- `AWS_ACCESS_KEY_ID` = `<IAM access key>`
- `AWS_SECRET_ACCESS_KEY` = `<IAM secret key>`
- `TERRAFORM_STATE_BUCKET` = `<state bucket name>`
- `ARGOCD_GIT_TOKEN` = `<infra 레포에 push 가능한 PAT>`

`ARGOCD_GIT_TOKEN`은 CI가 infra 레포의 매니페스트를 자동 수정할 때만 필요합니다.

### 4-4. `ai-medicare` 레포 secrets

AI 서비스도 frontend/backend와 동일한 배포 대상이므로 아래 secrets를 등록합니다.

- `AWS_REGION` = `ap-northeast-2`
- `AWS_ACCOUNT_ID` = `<12자리 AWS 계정 ID>`
- `AWS_ACCESS_KEY_ID` = `<IAM access key>`
- `AWS_SECRET_ACCESS_KEY` = `<IAM secret key>`
- `ECR_AI_REPOSITORY` = `medical-service-ai`

전체 ECR URI를 넣고 싶으면:

- `ECR_AI_URI` = `123456789012.dkr.ecr.ap-northeast-2.amazonaws.com/medical-service-ai`

선택 사항 (AI가 RDS에 직접 접근해야 할 때만):

- `DATABASE_URL` = `mysql://<user>:<password>@<rds-endpoint>:3306/<dbname>`

`DATABASE_URL`은 AI 서비스가 RDS의 데이터를 직접 읽어야 할 때만 필요합니다. 만약 AI 서비스가 백엔드를 통해서만 데이터에 접근한다면 백엔드에 `DATABASE_URL`을 두고 AI는 백엔드 API만 호출해도 됩니다.

## 5. Terraform 결과 점검: EKS / RDS 상태 확인

Terraform 1차 실행이 끝났다면 아래를 바로 확인합니다.

### 5-1. 생성 순서

Terraform으로 아래를 만듭니다.

- VPC
- Subnet
- Security Group
- Aurora(MySQL Compatible)

EKS Cluster / Node Group는 2차 적용에서 별도로 생성합니다.

### 5-2. 점검 명령

```bash
aws eks update-kubeconfig --region ap-northeast-2 --name <EKS_CLUSTER_NAME>
kubectl get nodes
```

### 5-3. 꼭 확인할 것

- `kubectl get nodes`가 정상적으로 나오는가
- EKS 워커 노드가 `Ready` 상태인가
- RDS endpoint가 출력되는가

EKS 노드가 없으면 Argo CD가 배포를 해도 Pod가 올라가지 않습니다.

## 6. GitHub Actions로 프론트/백 CI 활성화

Terraform 1차 실행으로 ECR이 준비되었기 때문에 이제 GitHub Actions가 이미지를 push할 수 있습니다.

### 6-1. 프론트 CI 흐름

`frontend-medicare/.github/workflows/frontend-ci-cd.yml`에서는 보통 아래 순서를 사용합니다.

1. Checkout
2. Node 설치
3. 의존성 설치 및 빌드
4. Docker build
5. ECR login
6. Docker push

### 6-2. 백엔드 CI 흐름

`backend-medicare/.github/workflows/backend-ci-cd.yml`에서는 보통 아래 순서를 사용합니다.

1. Checkout
2. Node 또는 Java 런타임 설치
3. 테스트 / 빌드
4. Docker build
5. ECR login
6. Docker push

### 6-3. 백엔드 워크플로 예시

현재 구조는 아래처럼 쓰면 됩니다.

```yaml
name: Backend CI/CD

on:
  push:
    branches: [ main ]

jobs:
  build-and-push:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Configure AWS credentials
        uses: aws-actions/configure-aws-credentials@v4
        with:
          aws-access-key-id: ${{ secrets.AWS_ACCESS_KEY_ID }}
          aws-secret-access-key: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
          aws-region: ${{ secrets.AWS_REGION }}

      - name: Login to Amazon ECR
        uses: aws-actions/amazon-ecr-login@v2

      - name: Build, tag, and push image to ECR
        env:
          ECR_REPOSITORY: ${{ secrets.ECR_BACKEND_REPOSITORY }}
          IMAGE_TAG: ${{ github.sha }}
        run: |
          REPO_URI="${{ secrets.AWS_ACCOUNT_ID }}.dkr.ecr.${{ secrets.AWS_REGION }}.amazonaws.com/${ECR_REPOSITORY}"
          docker build -t ${REPO_URI}:${IMAGE_TAG} .
          docker push ${REPO_URI}:${IMAGE_TAG}
```

### 6-4. CI가 실제로 성공했는지 확인

GitHub Actions에서 다음을 확인합니다.

- 워크플로 실행 성공
- ECR repository에 이미지 생성
- 태그가 `github.sha` 값으로 올라갔는지 확인

## 7. Argo CD 설치 준비

EKS가 준비된 뒤에 Argo CD를 설치합니다.

### 7-1. kubeconfig 연결

```bash
aws eks update-kubeconfig --region ap-northeast-2 --name <EKS_CLUSTER_NAME>
kubectl get nodes
```

### 7-2. Argo CD 설치

```bash
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
```

### 7-3. Argo CD 접속 확인

```bash
kubectl get pods -n argocd
```

필요하면 포트포워딩으로 UI를 확인합니다.

```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

## 8. Argo CD application.yaml 연결

`infra-medicare/argocd/application.yaml`은 Argo CD가 어느 Git 레포를 보고 어느 경로를 배포할지 정의합니다.

### 8-1. 반드시 실제 값으로 바꿔야 하는 것

- `spec.source.repoURL`
- `spec.source.path`
- `spec.destination.namespace`

예시:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: medical-service
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/<YOUR_ORG>/infra-medicare.git
    targetRevision: main
    path: k8s/overlays/prod
  destination:
    server: https://kubernetes.default.svc
    namespace: medical-service
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

### 8-2. 적용 명령

```bash
kubectl apply -f infra-medicare/argocd/application.yaml -n argocd
kubectl get applications -n argocd
```

## 9. k8s 매니페스트의 이미지 태그 갱신

Argo CD는 Git에 있는 매니페스트를 보고 배포합니다. 즉, 이미지가 바뀌면 매니페스트도 바뀌어야 합니다.

### 9-1. 가장 쉬운 방식

- `infra-medicare/k8s/base/backend-deployment.yaml`의 `image:` 값을 실제 ECR 이미지로 바꾼다
- 또는 `infra-medicare/k8s/overlays/prod/kustomization.yaml`에서 `images:`로 덮어쓴다

### 9-2. kustomize 방식 예시

```yaml
images:
  - name: backend
    newName: 123456789012.dkr.ecr.ap-northeast-2.amazonaws.com/backend-medicare
    newTag: v1.0.0
  - name: frontend
    newName: 123456789012.dkr.ecr.ap-northeast-2.amazonaws.com/frontend-medicare
    newTag: v1.0.0
  - name: ai
    newName: 123456789012.dkr.ecr.ap-northeast-2.amazonaws.com/ai-medicare
    newTag: v1.0.0
```

### 9-3. 이미지 업데이트를 누가 하느냐

둘 중 하나로 갑니다.

- 수동: CI 후 사람이 `kustomization.yaml` 수정하고 push
- 자동: CI가 `infra-medicare` 레포에 커밋하고 push

자동으로 할 경우 `ARGOCD_GIT_TOKEN`이 필요합니다.

### 9-4. AI 이미지도 동일 overlay에 포함

현재 구조에서는 AI도 frontend/backend와 동일하게 `k8s/overlays/prod`의 `images:`에 함께 포함하면 됩니다.
즉 별도 Argo CD Application을 추가하지 않고, `medical-service` 단일 Application에서 같이 Sync 합니다.
운영 시에는 `ECR_AI_REPOSITORY`, `DATABASE_URL`, `MODEL_ENV` 값만 누락되지 않게 관리하면 됩니다.

## 10. 추천 실행 순서 요약

실제로는 아래 순서로 진행하면 됩니다.

### AWS 계정 받기 전

1. 로컬 개발 도구 설치
2. `frontend-medicare`, `backend-medicare`, `ai-medicare`, `infra-medicare` 레포 생성
3. 프론트/백 기본 코드와 Dockerfile 준비
4. AI 기본 코드와 FastAPI, scikit-learn, 더미 데이터 스크립트 준비

### AWS 계정 받은 직후

1. `aws configure`
2. S3 + DynamoDB로 Terraform state backend 생성
3. Terraform 1차 실행으로 ECR/VPC/RDS 생성, 2차 실행으로 EKS 생성
4. GitHub Secrets 등록

### 그다음

1. GitHub Actions로 이미지 push 확인
2. `kubectl get nodes` 확인
3. Argo CD 설치
4. `application.yaml` 연결
5. k8s 이미지 태그 업데이트
6. Argo CD 배포 확인
7. AI 서비스 배포 및 백엔드 연동 확인

같이 배포 원칙:

- frontend/backend/ai 모두 동일하게 `k8s/overlays/prod`에 포함
- Argo CD `medical-service` Application 1개에서 함께 Sync
- 배포 순서는 이미지 push 후 overlay 이미지 태그 갱신 -> Argo CD Sync

## 11. GitHub Secrets 한 번에 정리

### frontend-medicare

- `AWS_REGION`
- `AWS_ACCOUNT_ID`
- `AWS_ACCESS_KEY_ID`
- `AWS_SECRET_ACCESS_KEY`
- `ECR_FRONTEND_REPOSITORY`

### backend-medicare

- `AWS_REGION`
- `AWS_ACCOUNT_ID`
- `AWS_ACCESS_KEY_ID`
- `AWS_SECRET_ACCESS_KEY`
- `ECR_BACKEND_REPOSITORY`

### ai-medicare

- `AWS_REGION`
- `AWS_ACCOUNT_ID`
- `AWS_ACCESS_KEY_ID`
- `AWS_SECRET_ACCESS_KEY`
- `ECR_AI_REPOSITORY`
- `DATABASE_URL`
- `MODEL_ENV`

### infra-medicare

- `AWS_REGION`
- `AWS_ACCOUNT_ID`
- `AWS_ACCESS_KEY_ID`
- `AWS_SECRET_ACCESS_KEY`
- `TERRAFORM_STATE_BUCKET`
- `ARGOCD_GIT_TOKEN` (자동 커밋할 때만)

## 12. 자주 막히는 지점

- **ECR이 없는데 CI를 먼저 돌림**: 안 됩니다. Terraform으로 ECR 먼저 만들어야 합니다.
- **EKS 노드 그룹이 없음**: Argo CD는 배포해도 Pod가 안 뜹니다.
- **`repoURL`이 실제 GitHub 주소가 아님**: Argo CD가 소스를 못 찾습니다.
- **GitHub Secrets 누락**: CI에서 AWS login이나 ECR push가 실패합니다.
- **AWS 키를 Git에 커밋**: 절대 하면 안 됩니다.

- **AI 레포를 프론트에 직접 연결**: 보통은 백엔드가 AI를 호출하는 구조가 더 낫습니다.

- **AI ECR을 Terraform 대상에서 누락함**: AI도 다른 서비스처럼 ECR이 필요합니다.

## 13. 최종 체크리스트

- [ ] 로컬 도구 설치 완료
- [ ] GitHub 레포 4개 생성 완료
- [ ] AI 레포 `ai-medicare` 생성 완료
- [ ] AWS 계정 수령 후 `aws configure` 완료
- [ ] S3 + DynamoDB state backend 생성 완료
- [ ] Terraform 1차 실행으로 ECR/VPC/Aurora 생성 완료
- [ ] Terraform 2차 실행으로 EKS 생성 완료
- [ ] AI ECR 생성 완료
- [ ] GitHub Secrets 등록 완료
- [ ] CI로 ECR push 성공 확인
- [ ] `kubectl get nodes` 정상
- [ ] Argo CD 설치 완료
- [ ] `application.yaml` 실제 repoURL/path 반영 완료
- [ ] k8s 이미지 태그 반영 완료
- [ ] AI 서비스 배포 완료
- [ ] 백엔드가 AI API 호출 확인
- [ ] Argo CD에서 `Synced & Healthy` 확인
