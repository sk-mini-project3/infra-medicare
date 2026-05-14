# Medical Service Infrastructure

의료 서비스 플랫폼의 **AWS 인프라와 실제 운영 배포**를 관리하는 저장소입니다. 인프라는 **Terraform**으로 정의하고, 앱은 **EC2에서 Docker로 실행**하며 **Application Load Balancer**로 노출합니다. 코드 반영은 **GitHub Actions → GHCR** 이미지를 **AWS Systems Manager(Run Command)** 로 EC2에 내려 **SSH 없이** 진행합니다.

배포 절차·워크플로·검증 체크리스트 등 **실무 기준 문서**는 **[infra.md](infra.md)** 를 따릅니다.

---

## 이 레포의 역할

- Terraform으로 **VPC, Aurora MySQL, ElastiCache(Redis), ECR, EKS** 등 이 프로젝트에 포함된 AWS 리소스 정의
- **GHCR** 이미지를 EC2에서 `docker pull` 후 컨테이너 기동·재기동하는 **SSM 배포 스크립트**(`scripts/*.ps1` 등)
- EC2 부트스트랩 **예시** (루트의 `.aws-userdata-*.sh`), IAM 정책 **예시 JSON** (`examples/aws-iam/`)
- 배포·아키텍처 요약 문서 (`md/`)

---

## 배포 흐름(요약)

1. **프론트·백엔드·AI** 각 앱 레포에서 CI 조건에 맞게 푸시 → **GitHub Actions**가 이미지를 **GHCR**에 푸시합니다.
2. 운영자 PC에서 **AWS CLI**로 대상 계정·리전(예: `ap-northeast-2`) 인증 후, 레포 **`scripts/`** 에서 SSM용 PowerShell 스크립트를 실행해 대상 EC2에 Run Command를 보냅니다.
3. `medical-backend.env`, `medical-ai.env` 는 로컬에서 최신 연결 정보로 맞춘 뒤 스크립트에 경로를 넘깁니다. **민감값은 Git에 커밋하지 않습니다.**

백엔드·AI·프론트별 명령 예시, 사전 조건(SSM Online, Secrets Manager로 GHCR 로그인 등), 배포 성공 확인은 **[infra.md](infra.md)** 의 **§3·§4** 를 참고합니다.

---

## 기술 스택(현재 운영 기준)

| 구분 | 사용 |
| --- | --- |
| 인프라 | Terraform, AWS(VPC, ALB, EC2, Aurora MySQL, ElastiCache, ECR 등) |
| 이미지 | GitHub Actions, **GitHub Container Registry(GHCR)** |
| 런타임·진입 | **Docker** on **EC2**, **Application Load Balancer** |
| 배포 | **AWS Systems Manager** Run Command, **Secrets Manager**(GHCR 자격 등) |
| 도구 | AWS CLI, **PowerShell**(배포 스크립트) |

---

## 아키텍처(한 줄)

서비스별 앱 레포 → **GitHub Actions** → **GHCR** → 운영자 **SSM Run Command** → **EC2(Docker)** → **ALB** → 사용자. 백엔드는 **Aurora·Redis** 및 환경 변수의 **AI ALB URL** 등과 연결합니다. 상세 그림·설명은 [infra.md](infra.md)입니다.

---

## 문서

| 문서 | 내용 |
| --- | --- |
| **[infra.md](infra.md)** | 실제 배포 방식 전체(결정 사항, 구성 요소, 절차, 검증, 보안 메모) |
| **[DEPLOYMENT_ISSUES_AND_RESOLUTIONS.md](DEPLOYMENT_ISSUES_AND_RESOLUTIONS.md)** | 배포 진행 중 겪은 어려움과 해결(채팅·진행 기록 기반) |

---

## 프로젝트 구조

레포 루트 `medical-service-infra/` 기준입니다.

```text
medical-service-infra/
├── md/
│   ├── README.md
│   ├── infra.md
│   ├── DEPLOYMENT_ISSUES_AND_RESOLUTIONS.md
│   └── EKS_ArgoCD_배포_가이드.md
├── medical-backend.env
├── medical-ai.env
├── examples/
│   └── aws-iam/                    ← EC2 역할 신뢰·인라인 정책 예시(JSON)
│       ├── aws-iam-trust-ec2.json
│       ├── aws-iam-fe-ec2-policy.json
│       └── aws-iam-backend-ssm-secrets.json
├── .aws-userdata-plain.sh
├── .aws-userdata-frontend-docker.sh
├── terraform/
│   ├── backend.tf
│   ├── provider.tf
│   ├── versions.tf
│   ├── variables.tf
│   ├── terraform.tfvars
│   ├── vpc.tf
│   ├── rds.tf
│   ├── ecr.tf
│   ├── eks.tf
│   └── outputs.tf
├── k8s/
│   ├── base/
│   └── overlays/
│       ├── dev/
│       └── prod/
├── argocd/
│   ├── application.yaml
│   └── README.md
└── scripts/
    ├── deploy-backend-ssm.ps1
    ├── deploy-frontend-ssm.ps1
    ├── deploy-ai-ssm.ps1
    ├── deploy-backend-ec2-instance-connect.ps1
    ├── fe-ssm-bootstrap.sh
    ├── aws-cli-ec2-alb-backend.sh
    ├── deploy.sh
    └── update-image-tags.sh
```

---

## Terraform 빠른 시작

```bash
cd medical-service-infra/terraform
terraform init
terraform plan
terraform apply
```

리소스 생성 후 **앱 이미지 반영**은 [infra.md](infra.md)의 SSM 배포 절차를 따릅니다.

---

## 운영 전에 확인할 것

- `terraform.tfvars`, `backend.tf` 의 변수·state 백엔드(S3·DynamoDB)
- EC2 인스턴스 프로파일에 SSM 권한, **PingStatus=Online**
- 비공개 GHCR: Secrets Manager + EC2 IAM `secretsmanager:GetSecretValue`

---

## 주의사항

- AWS 키, DB 비밀번호, GitHub·GHCR 토큰은 **Git에 올리지 않습니다.**
- `medical-backend.env`, `medical-ai.env`, `terraform.tfvars` 는 `.gitignore`·팀 정책에 맞게 관리합니다.
- SSM·CI 로그에 시크릿이 남지 않게 합니다.

---

추후 **EKS·Argo CD** 는 **[EKS_ArgoCD_배포_가이드.md](EKS_ArgoCD_배포_가이드.md)** 순서로 진행할 예정입니다.
