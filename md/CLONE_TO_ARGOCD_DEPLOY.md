# Clone 후 배포 가이드 (내 환경 기준)

이 문서는 `mini_project_3` 기준으로 정리했습니다.

- AWS Account ID: `296336226405` (현재 prod kustomization 기준)
- Region: `ap-northeast-2`
- Namespace: `medical-service`
- 서비스 포트
  - frontend: 컨테이너 `80` (로컬 접근 `8080:80`)
  - backend: `3000`
  - ai: `8001`

---

## 0) 핵심 질문 답변

### Q. "4. 이미지 태그/푸시" 부분, 그냥 CMD에 입력하면 되나요?

네. **Windows CMD에서 그대로 실행 가능한 형태**로 아래 명령을 적어두었습니다.  
PowerShell이 아니라 CMD 기준으로 작성했습니다.

---

## 1) 클론 직후: 로컬 Docker 빌드 먼저

### 1-1. frontend

```cmd
cd C:\mini_project_3\medical-service-frontend
docker build -t medical-service-frontend:local .
docker run --rm -p 8080:80 medical-service-frontend:local
```

### 1-2. backend

```cmd
cd C:\mini_project_3\medical-service-backend
docker build -t medical-service-backend:local .
docker run --rm -p 3000:3000 --env-file .env medical-service-backend:local
```

### 1-3. ai

```cmd
cd C:\mini_project_3\ai-medicare
docker build -t medical-service-ai:local .
docker run --rm -p 8001:8001 medical-service-ai:local
```

---

## 2) Terraform으로 EKS 설치

Terraform 코드는 `medical-service-infra/terraform`를 사용합니다.

### 2-1. 사전 준비 (state 저장소)

```cmd
aws configure
aws sts get-caller-identity
```

S3 버킷/락 테이블이 없다면 생성:

```cmd
aws s3 mb s3://mini3-tfstate-prod --region ap-northeast-2
aws dynamodb create-table --table-name terraform-locks --attribute-definitions AttributeName=LockID,AttributeType=S --key-schema AttributeName=LockID,KeyType=HASH --provisioned-throughput ReadCapacityUnits=5,WriteCapacityUnits=5 --region ap-northeast-2
```

### 2-2. tfvars 작성

`C:\mini_project_3\medical-service-infra\terraform\terraform.tfvars` 생성:

```hcl
aws_region = "ap-northeast-2"
project_name = "medical-service"
db_password = "강한비밀번호로변경"
```

### 2-3. init / plan / apply

```cmd
cd C:\mini_project_3\medical-service-infra\terraform
terraform init -backend-config="bucket=mini3-tfstate-prod" -backend-config="key=medical-service/terraform.tfstate" -backend-config="region=ap-northeast-2" -backend-config="dynamodb_table=terraform-locks" -backend-config="encrypt=true"
terraform plan -out tfplan
terraform apply tfplan
```

### 2-4. EKS 연결

```cmd
terraform output eks_cluster_name
aws eks update-kubeconfig --region ap-northeast-2 --name medical-service-eks
kubectl get nodes
```

> 클러스터명이 다르면 `terraform output eks_cluster_name` 결과값으로 바꿔서 실행하세요.

---

## 3) ECR 로그인 + 수동 이미지 태그/푸시 (CMD 그대로)

### 3-1. ECR 로그인

```cmd
aws ecr get-login-password --region ap-northeast-2 | docker login --username AWS --password-stdin 296336226405.dkr.ecr.ap-northeast-2.amazonaws.com
```

### 3-2. 태그 변수

```cmd
set TAG=manual-%DATE:~0,4%%DATE:~5,2%%DATE:~8,2%-%TIME:~0,2%%TIME:~3,2%%TIME:~6,2%
set TAG=%TAG: =0%
```

### 3-3. frontend push

```cmd
cd C:\mini_project_3\medical-service-frontend
docker tag medical-service-frontend:local 296336226405.dkr.ecr.ap-northeast-2.amazonaws.com/medical-service-frontend:%TAG%
docker push 296336226405.dkr.ecr.ap-northeast-2.amazonaws.com/medical-service-frontend:%TAG%
```

### 3-4. backend push

```cmd
cd C:\mini_project_3\medical-service-backend
docker tag medical-service-backend:local 296336226405.dkr.ecr.ap-northeast-2.amazonaws.com/medical-service-backend:%TAG%
docker push 296336226405.dkr.ecr.ap-northeast-2.amazonaws.com/medical-service-backend:%TAG%
```

### 3-5. ai push

```cmd
cd C:\mini_project_3\ai-medicare
docker tag medical-service-ai:local 296336226405.dkr.ecr.ap-northeast-2.amazonaws.com/medical-service-ai:%TAG%
docker push 296336226405.dkr.ecr.ap-northeast-2.amazonaws.com/medical-service-ai:%TAG%
```

---

## 4) k8s prod kustomization 수정

파일: `C:\mini_project_3\medical-service-infra\k8s\overlays\prod\kustomization.yaml`

`images` 섹션의 `newTag`를 `%TAG%`로 맞춥니다.

- frontend `newTag`
- backend `newTag`
- ai `newTag`

`REDIS_HOST`, `YOUR_DOMAIN.com`도 실제 값으로 수정하세요.

---

## 5) DB/Redis/JWT Secret 생성 (AFTER_EKS Step 2)

이 단계는 **EKS 연결(2-4) 후**, **kubectl apply -k 실행 전에** 해야 합니다.  
즉, 현재 문서 순서에서는 `4) kustomization 수정` 다음에 진행하면 됩니다.

```cmd
cd C:\mini_project_3\medical-service-infra\terraform
for /f "delims=" %i in ('terraform output -raw rds_address') do set RDS_ENDPOINT=%i

kubectl create secret generic db-credentials ^
  --namespace medical-service ^
  --from-literal=DB_USERNAME=admin ^
  --from-literal=DB_PASSWORD=실제_비밀번호_입력 ^
  --from-literal=SPRING_DATASOURCE_URL=jdbc:mysql://%RDS_ENDPOINT%:3306/medicalservicedb?useSSL=false^&allowPublicKeyRetrieval=true^&serverTimezone=Asia/Seoul^&characterEncoding=UTF-8 ^
  --from-literal=REDIS_PASSWORD= ^
  --from-literal=JWT_SECRET=팀에서_받은_256비트_이상_값 ^
  --from-literal=ENCRYPTION_KEY=팀에서_받은_암호화_키 ^
  --dry-run=client -o yaml | kubectl apply -f -
```

확인:

```cmd
kubectl get secret db-credentials -n medical-service
kubectl get secret db-credentials -n medical-service -o jsonpath="{.data.DB_USERNAME}" | base64 --decode
```

---

## 6) kubectl 수동 배포 검증 (최초 1회)

```cmd
cd C:\mini_project_3\medical-service-infra
kubectl apply -k k8s/overlays/prod
kubectl get pods -n medical-service
kubectl get svc -n medical-service
kubectl get ingress -n medical-service
```

로그 확인:

```cmd
kubectl logs -n medical-service deployment/frontend
kubectl logs -n medical-service deployment/backend
kubectl logs -n medical-service deployment/ai
```

---

## 7) ArgoCD 설치 및 연결

### 6-1. 설치

```cmd
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl get pods -n argocd
```

초기 비밀번호:

```cmd
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 --decode
```

### 6-2. Application 등록 (예시)

```cmd
argocd app create medical-service --repo <INFRA_REPO_URL> --path k8s/overlays/prod --dest-server https://kubernetes.default.svc --dest-namespace medical-service --sync-policy automated --auto-prune --self-heal
argocd app sync medical-service
argocd app wait medical-service
```

---

## 8) GitHub Actions 활성화 (마지막 단계)

서비스 리포별 GitHub Secrets:

- 공통
  - `AWS_ACCESS_KEY_ID`
  - `AWS_SECRET_ACCESS_KEY`
  - `AWS_REGION` = `ap-northeast-2`
  - `AWS_ACCOUNT_ID` = `296336226405`
- frontend: `ECR_FRONTEND_REPOSITORY` = `medical-service-frontend`
- backend: `ECR_BACKEND_REPOSITORY` = `medical-service-backend`
- ai: `ECR_AI_REPOSITORY` = `medical-service-ai`

이후 `main` 푸시하면:

1. 이미지 build/push  
2. infra `kustomization.yaml` 이미지 태그 업데이트 PR 생성  
3. PR 머지 시 ArgoCD 자동 반영

---

## 9) 추천 실행 순서 (실무형)

1. 로컬 Docker 빌드 3개 성공 확인  
2. Terraform으로 EKS 생성/연결  
3. 수동 이미지 push + Secret 생성 + `kubectl apply -k` 1회 검증  
4. ArgoCD 설치/앱 연결  
5. GitHub Actions 푸시 및 자동 배포 전환

