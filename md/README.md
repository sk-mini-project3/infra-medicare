# Medical Service Infrastructure

의료 서비스 플랫폼의 인프라를 관리하는 저장소입니다. 이 레포는 AWS 인프라를 Terraform으로 만들고, Kubernetes 매니페스트와 Argo CD를 통해 서비스 배포 흐름을 관리합니다.

이 저장소의 핵심 역할은 다음과 같습니다.

- AWS 기반 인프라 코드 관리
- ECR, VPC, Aurora MySQL, EKS 리소스 생성
- Kubernetes 기본 매니페스트 및 프로덕션 오버레이 관리
- Argo CD 기반 GitOps 배포 연결
- 배포 절차와 체크리스트 문서화

---

## 주요 기능

### 인프라 코드

- Terraform으로 모든 AWS 리소스를 선언적으로 관리합니다.
- Phase 1과 Phase 2로 나누어 인프라를 단계적으로 생성합니다.
- backend 설정을 통해 Terraform state를 S3와 DynamoDB에 안전하게 보관합니다.

### Kubernetes 배포

- `k8s/base`에는 공통 리소스를 정의합니다.
- `k8s/overlays/prod`에는 운영 배포용 이미지 태그와 환경 설정을 정의합니다.
- Kustomize로 서비스별 이미지와 설정을 쉽게 교체할 수 있습니다.

### GitOps

- Argo CD가 Git 저장소 상태를 기준으로 EKS에 자동 동기화합니다.
- 이미지 태그를 변경한 뒤 Git 커밋만 하면 배포 상태가 따라갑니다.

### 문서화

- `md/DEPLOY.md`: 전체 배포 가이드
- `md/DEPLOYMENT_CHECKLIST.md`: 배포 체크리스트
- `md/POST_CLONE_SETUP.md`: 서비스 clone 후 로컬 테스트 가이드
- `md/AFTER_EKS.md`: EKS 설치 이후 배포 가이드
- `md/infra_guide.md`: 구조와 개념 중심의 상세 가이드

---

## 기술 스택

### Infrastructure

- Terraform
- AWS
- Amazon ECR
- Amazon VPC
- Amazon RDS Aurora MySQL
- Amazon EKS
- Amazon S3
- Amazon DynamoDB

### Deployment

- Kubernetes
- Kustomize
- Argo CD

### DevOps / Local

- Docker
- Docker Compose
- GitHub Actions
- AWS CLI
- kubectl

---

## 아키텍처 개요

이 프로젝트는 서비스 레포와 인프라 레포를 분리한 멀티 레포 구조입니다.

```text
frontend-medicare     backend-medicare     ai-medicare
	 \                  |                  /
	  \                 |                 /
	   \        GitHub Actions CI        /
	    \        build -> push          /
	     \              |              /
	      \             v             /
		---> Amazon ECR repositories
			   |
			   v
		   Kubernetes on EKS
			   |
			   v
		 Argo CD GitOps sync
			   |
			   v
		   medical-service-infra
```

### 배포 흐름 요약

1. 각 서비스 레포에 코드가 `main` 브랜치로 푸시됩니다.
2. GitHub Actions가 Docker 이미지를 빌드합니다.
3. 이미지를 Amazon ECR에 푸시합니다.
4. 인프라 레포의 `k8s/overlays/prod/kustomization.yaml`에서 이미지 태그를 갱신합니다.
5. 인프라 레포에 커밋을 푸시합니다.
6. Argo CD가 Git 변경을 감지하고 EKS에 동기화합니다.
7. Kubernetes가 롤링 업데이트를 수행합니다.

### 구성요소 역할

- **ECR**: 서비스 이미지 저장소
- **EKS**: Kubernetes 실행 환경
- **RDS Aurora**: 백엔드 데이터베이스
- **VPC**: 퍼블릭/프라이빗 네트워크 분리
- **Argo CD**: GitOps 배포 자동화
- **Terraform**: AWS 인프라 관리

---

## 프로젝트 구조

```text
medical-service-infra/
├── README.md
├── docker-compose.yml
├── docker-compose.override.yml
├── md/
│   ├── DEPLOY.md
│   ├── DEPLOYMENT_CHECKLIST.md
│   ├── AFTER_EKS.md
│   ├── POST_CLONE_SETUP.md
│   └── infra_guide.md
├── terraform/
│   ├── backend.tf
│   ├── ecr.tf
│   ├── eks.tf
│   ├── outputs.tf
│   ├── provider.tf
│   ├── rds.tf
│   ├── variables.tf
│   ├── versions.tf
│   ├── vpc.tf
│   └── terraform.tfvars
├── k8s/
│   ├── base/
│   │   ├── ai-deployment.yaml
│   │   ├── ai-service.yaml
│   │   ├── backend-deployment.yaml
│   │   ├── configmap.yaml
│   │   ├── frontend-deployment.yaml
│   │   ├── ingress.yaml
│   │   ├── kustomization.yaml
│   │   ├── secret.yaml
│   │   └── service.yaml
│   └── overlays/
│       ├── dev/
│       │   └── kustomization.yaml
│       └── prod/
│           └── kustomization.yaml
├── argocd/
│   └── application.yaml
└── scripts/
    ├── deploy.sh
    └── update-image-tags.sh
```

---

## 배포 흐름

### 1. 초기 인프라 준비

최초 1회만 수행합니다.

1. AWS CLI 인증 설정
2. Terraform state backend용 S3 버킷과 DynamoDB 테이블 생성
3. Terraform Phase 1 실행: ECR, VPC, Aurora 생성
4. Terraform Phase 2 실행: EKS 생성
5. `aws eks update-kubeconfig` 실행
6. Argo CD 설치 및 접근 설정

### 2. 서비스 개발 완료 후

1. 프론트엔드, 백엔드, AI 레포에 코드 푸시
2. GitHub Actions가 Docker 이미지를 빌드하고 ECR에 푸시
3. 인프라 레포의 Kustomize 이미지 태그를 업데이트
4. 인프라 레포에 커밋 후 푸시
5. Argo CD가 변경을 감지하고 EKS에 배포

### 3. 운영 중 업데이트

1. 이미지 재빌드 및 ECR 푸시
2. `kustomization.yaml`의 `newTag` 갱신
3. Git 커밋 및 푸시
4. Argo CD 자동 동기화

---

## 운영 전 준비 항목

### Terraform

- `terraform.tfvars`의 비밀번호와 변수 값 확인
- backend 설정에서 S3 버킷, DynamoDB 테이블, key 확인
- Phase 1과 Phase 2를 분리해서 실행

### Kubernetes

- `k8s/base`의 Deployment와 Service 포트 일치 확인
- `k8s/overlays/prod/kustomization.yaml`의 ECR URI 및 태그 확인
- `secret.yaml`은 Git에 커밋하지 않고 `kubectl create secret`로 주입

### Argo CD

- `argocd/application.yaml`의 `repoURL`과 `path` 확인
- GitHub repo 연결 방식 확인
- 자동 동기화 정책 여부 확인

---

## 배포 전 체크포인트

- ECR 이미지가 정상적으로 푸시되었는가
- `kustomization.yaml`의 `images` 항목이 최신 SHA를 가리키는가
- Argo CD Application이 `Synced` 상태인가
- Pod가 `Running` 상태인가
- Backend가 RDS에 연결되는가
- Frontend가 Backend API에 연결되는가
- AI 서비스가 Backend와 통신하는가

---

## 로컬 개발 참고

이 저장소는 로컬 개발용으로도 사용할 수 있습니다.

- `docker-compose.yml`로 서비스 간 통합 테스트 가능
- 각 서비스는 개별 Docker 이미지로 빌드 가능
- 서비스가 완성되면 로컬에서 먼저 기동 확인 후 EKS 배포로 넘어가는 것을 권장합니다.

---

## 관련 문서

- [md/DEPLOY.md](md/DEPLOY.md)
- [md/DEPLOYMENT_CHECKLIST.md](md/DEPLOYMENT_CHECKLIST.md)
- [md/POST_CLONE_SETUP.md](md/POST_CLONE_SETUP.md)
- [md/AFTER_EKS.md](md/AFTER_EKS.md)
- [md/infra_guide.md](md/infra_guide.md)

---

## 주의사항

- AWS 키, DB 비밀번호, GitHub PAT는 절대 커밋하지 않습니다.
- `k8s/base/secret.yaml` 같은 민감 정보 파일은 실제 값 없이 관리하거나 Git 추적에서 제외합니다.
- EKS 생성 전에는 ECR, VPC, Aurora 중심으로 작업하고, EKS와 Argo CD는 배포 시점에 맞춰 생성하는 것이 비용 효율적입니다.

---

## 빠른 시작

```bash
cd medical-service-infra/terraform
terraform init
terraform plan
terraform apply
```

배포는 문서 순서대로 진행하면 됩니다.
