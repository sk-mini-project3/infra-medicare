# 의료 서비스 배포 체크리스트

> **상태**: 코드 대기 중 (EKS 생성 전)  
> **마지막 업데이트**: 2026-05-08

---

## 📋 현재 완료 상태

### ✅ 이미 완료된 것
- [x] Terraform Phase 1 (ECR, VPC, Aurora)
- [x] GitHub Secrets 등록 (AWS_ACCOUNT_ID, AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY)
- [x] k8s 매니페스트 준비
- [x] ArgoCD 설정 파일 준비
- [x] 배포 스크립트 준비

### ⏳ 대기 중 (코드 들어올 때 진행)
- [ ] 각 서비스 레포에 코드 푸시 (frontend, backend, ai)
- [ ] GitHub Actions 실행 (자동 빌드 & ECR 푸시)
- [ ] Terraform Phase 2 (EKS 클러스터 생성)

---

## 🚀 배포 흐름 (코드 들어오면)

### Step 1: 코드 푸시 (5분)
```bash
# 각 레포에서
git add .
git commit -m "init: initial scaffold"
git push origin main

# GitHub Actions 자동 실행
# → Docker 빌드
# → ECR 푸시
```

**확인 방법:**
- GitHub 각 레포의 Actions 탭 → ✅ 초록색 체크

### Step 2: EKS 클러스터 생성 (20분)
```bash
cd medical-service-infra/terraform

# 전체 리소스 생성 (Phase 1은 이미 생성됨)
terraform apply

# 클러스터 접근 설정
aws eks update-kubeconfig \
  --region ap-northeast-2 \
  --name medical-service

# 확인
kubectl cluster-info
kubectl get nodes
```

**확인 방항:**
```bash
# 예상 출력: 2개 노드가 Ready 상태
kubectl get nodes
NAME                                    STATUS   ROLES    AGE   VERSION
ip-10-0-xx-xxx.ap-northeast-2.compute...   Ready    <none>   2m    v1.27.x
ip-10-0-xx-xxx.ap-northeast-2.compute...   Ready    <none>   2m    v1.27.x
```

### Step 3: ECR 이미지 태그 확인 (1분)
```bash
# 각 서비스별 최신 이미지 확인
aws ecr describe-images \
  --repository-name medical-service-frontend \
  --region ap-northeast-2 \
  --query 'imageDetails[0].[imageTags[0],imagePushedAt]' \
  --output text

# 출력: sha-a1b2c3d4    2026-05-08T10:30:00+00:00
```

기록해둘 값:
- Frontend 이미지 태그: `sha-xxxxx`
- Backend 이미지 태그: `sha-xxxxx`
- AI 이미지 태그: `sha-xxxxx`

### Step 4: 이미지 태그 업데이트 (2분)
```bash
cd medical-service-infra

# 방법 1: 자동 스크립트 (권장)
./scripts/update-image-tags.sh a1b2c3d4

# 또는 방법 2: 수동 편집
# k8s/overlays/prod/kustomization.yaml 수정
# images[0].newTag: "sha-a1b2c3d4"
# images[1].newTag: "sha-e5f6g7h8"
# images[2].newTag: "sha-i9j0k1l2"

# 커밋 & 푸시
git add k8s/overlays/prod/kustomization.yaml
git commit -m "ci: update image tags to sha-a1b2c3d4, sha-e5f6g7h8, sha-i9j0k1l2"
git push origin main
```

### Step 5: ArgoCD 설치 (5분)
```bash
# ArgoCD 네임스페이스 생성
kubectl create namespace argocd

# ArgoCD 설치
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Pod 대기
kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=argocd-server -n argocd --timeout=300s

# 초기 암호 확인
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
```

### Step 6: ArgoCD 접근 및 GitHub 연결 (5분)
```bash
# Port forward
kubectl port-forward svc/argocd-server -n argocd 8080:443 &

# 브라우저: https://localhost:8080
# 사용자명: admin
# 비밀번호: [위에서 확인한 값]

# GitHub 레포 연결
# → Settings → Repositories → Connect Repo
# → URL: https://github.com/sk-mini-project3/infra-medicare.git
```

### Step 7: ArgoCD Application 배포 (2분)
```bash
# 적용
kubectl apply -f argocd/application.yaml

# 상태 확인
kubectl get application -n argocd

# 예상 출력: Synced, Healthy
kubectl get application medical-service -n argocd -o wide
```

### Step 8: Pod 배포 확인 (3분)
```bash
# 배포 상태 확인
kubectl get deployments
kubectl get pods

# 예상 출력: 각 서비스당 2개 Pod (frontend × 2, backend × 2, ai × 2)
kubectl get pods -o wide

# Pod 로그 확인
kubectl logs deployment/frontend -f
kubectl logs deployment/backend -f
kubectl logs deployment/ai -f

# 서비스 상태
kubectl get svc
```

---

## 🔍 배포 후 확인 사항

### 1️⃣ 네트워크 연결성 테스트

```bash
# Backend → RDS 연결 테스트
kubectl exec -it deployment/backend -- \
  mysql -h medical-service-aurora.xxxxx.ap-northeast-2.rds.amazonaws.com \
        -u admin -p medicalservicedb

# AI ↔ Backend 통신 테스트
kubectl exec -it deployment/ai -- \
  curl -v http://backend-service:80/health

# Frontend ↔ Backend 통신 테스트
kubectl exec -it deployment/frontend -- \
  curl -v http://backend-service:80/health
```

### 2️⃣ 환경 변수 확인

```bash
# Backend 환경 변수 확인
kubectl exec deployment/backend -- env | grep -E "AI_BASE_URL|LOG_LEVEL|DATABASE_URL"

# AI 환경 변수 확인
kubectl exec deployment/ai -- env | grep -E "BACKEND_API_URL|LOG_LEVEL"
```

### 3️⃣ ConfigMap & Secret 확인

```bash
# ConfigMap 조회
kubectl get cm app-config -o yaml

# Secret 조회 (암호화됨)
kubectl get secret db-credentials -o yaml
```

### 4️⃣ ArgoCD 대시보드

- https://localhost:8080/applications
- Application 상태: **Synced** ✅
- Health: **Healthy** ✅

---

## 🔧 트러블슈팅

### EKS 노드가 NotReady 상태
```bash
# 노드 상태 확인
kubectl describe node <NODE_NAME>

# 이벤트 확인
kubectl get events -A --sort-by='.lastTimestamp' | tail -20
```

### Pod 빌드 실패 (ImagePullBackOff)
```bash
# Pod 상세 정보
kubectl describe pod <POD_NAME>

# ECR 로그인 확인
aws ecr get-login-password --region ap-northeast-2 | \
  docker login --username AWS --password-stdin 296336226405.dkr.ecr.ap-northeast-2.amazonaws.com

# 이미지 존재 확인
aws ecr describe-images --repository-name medical-service-frontend --region ap-northeast-2
```

### ArgoCD 동기화 실패
```bash
# ArgoCD 컨트롤러 로그
kubectl logs -n argocd deployment/argocd-application-controller

# Application 상태
kubectl describe application medical-service -n argocd
```

### RDS 연결 실패
```bash
# Backend Pod에서 RDS 핑
kubectl exec deployment/backend -- \
  ping medical-service-aurora.xxxxx.ap-northeast-2.rds.amazonaws.com

# 보안 그룹 확인
aws ec2 describe-security-groups --region ap-northeast-2 \
  --filters Name=group-name,Values=medical-service-rds-sg
```

---

## 📝 기록용 템플릿

배포할 때 이 정보들을 기록해두세요:

```
=== 배포 정보 ===
배포 날짜: 
배포자: 
EKS 클러스터 생성 시간: 

=== ECR 이미지 정보 ===
Frontend 이미지 태그: sha-
Backend 이미지 태그: sha-
AI 이미지 태그: sha-

=== ArgoCD 정보 ===
ArgoCD 초기 암호: 
GitHub PAT (필요시): 

=== 배포 후 상태 ===
Frontend Pod: ✓ ✗
Backend Pod: ✓ ✗
AI Pod: ✓ ✗
RDS 연결: ✓ ✗
Backend → AI 통신: ✓ ✗
Frontend → Backend 통신: ✓ ✗
```

---

## 📞 빠른 참조

### 자주 사용하는 명령어

```bash
# 배포 상태 한눈에 보기
kubectl get all

# 모든 Pod 실시간 모니터링
kubectl get pods -w

# Pod 로그 스트림
kubectl logs -f deployment/backend

# 배포 다시 시작
kubectl rollout restart deployment/backend

# 배포 상태 확인
kubectl rollout status deployment/backend

# Kustomize 빌드 미리보기
kustomize build k8s/overlays/prod

# 배포 시뮬레이션 (실제 적용 안 함)
kubectl apply -f manifests.yaml --dry-run=client
```

---

**코드가 들어오면 이 체크리스트를 따라 진행하세요! 🚀**
