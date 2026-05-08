# EKS 설치 후 배포 가이드

> **현재 상황**: Phase 1-3 + Phase 5 완료 (ECR, VPC, RDS Aurora, GitHub Secrets 준비됨)
> **다음 단계**: EKS 설치 → ArgoCD 설정 → 서비스 배포

---

## Step 1. EKS 클러스터 생성 (Phase 4)

### 1-1. Terraform Phase 2 Apply

```bash
cd medical-service-infra/terraform

# EKS 클러스터 생성 (15~20분 소요)
terraform apply

# 완료 후 확인
terraform output eks_cluster_name
terraform output eks_cluster_endpoint
```

### 1-2. kubeconfig 연결

```bash
# 로컬 kubeconfig 업데이트
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

---

## Step 2. DB Secret 생성

```bash
# RDS Aurora 엔드포인트 확인
RDS_ENDPOINT=$(cd medical-service-infra/terraform && terraform output -raw rds_address)

# EKS에 Secret 생성
kubectl create secret generic db-credentials \
  --namespace default \
  --from-literal=DB_USERNAME=admin \
  --from-literal=DB_PASSWORD='실제_비밀번호_입력' \
  --from-literal=DATABASE_URL="jdbc:mysql://admin:실제_비밀번호_입력@${RDS_ENDPOINT}:3306/medicalservicedb"

# 확인
kubectl get secret db-credentials -o jsonpath='{.data.DB_USERNAME}' | base64 -d
```

---

## Step 3. ArgoCD 설치 (Phase 6)

### 3-1. ArgoCD 네임스페이스 및 설치

```bash
# 네임스페이스 생성
kubectl create namespace argocd

# ArgoCD 설치
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Pod 대기 (1~2분)
kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=argocd-server -n argocd --timeout=300s

# 확인
kubectl get pods -n argocd
```

### 3-2. ArgoCD 초기 비밀번호 확인

```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
echo ""  # 줄바꿈
```

**출력 예시:**
```
Hy7kX9mR2pQ5vL8nJ
```

### 3-3. ArgoCD 접근 (로컬)

```bash
# Port forward (터미널 1개 계속 유지)
kubectl port-forward svc/argocd-server -n argocd 8080:443

# 브라우저에서 열기
# https://localhost:8080
# 사용자명: admin
# 비밀번호: [위에서 얻은 값]
```

### 3-4. GitHub 레포 연결 (ArgoCD 콘솔)

ArgoCD 웹 UI에서:
1. **Settings** (⚙️) → **Repositories**
2. **Connect Repo** 클릭
3. **Connection Method**: HTTPS
4. **Repository URL**: `https://github.com/YOUR_ORG/medical-service-infra.git`
5. **Connect**

(개인 레포면 GitHub PAT 필요)

### 3-5. ArgoCD Application 생성

```bash
# medical-service-infra/argocd/application.yaml 확인
cat medical-service-infra/argocd/application.yaml

# 적용
kubectl apply -f medical-service-infra/argocd/application.yaml

# 상태 확인
kubectl get application -n argocd
```

---

## Step 4. 서비스 배포 준비 (개발 완성 후)

### 4-1. 서비스 코드 완성

**타이밍**: 모든 서비스(AI, 백엔드, 프론트엔드) 개발 완료 후

- ✅ AI: 모델 정확도 ↑ + 탐지 사유 + 이메일 알림
- ✅ 백엔드: API 개발 + DB 연동
- ✅ 프론트엔드: UI 개발 + 백엔드 통신

### 4-2. 워크플로우 파일 작성 및 푸시

각 서비스 레포에서 `.github/workflows/` 폴더에 파일 작성:

- `medical-service-frontend/.github/workflows/frontend-ci-cd.yml`
- `medical-service-backend/.github/workflows/backend-ci-cd.yml`
- `ai-medicare/.github/workflows/ai-ci-cd.yml`

**중요**: 이전에 준비된 임시 워크플로우 파일 → 최종 버전으로 교체

### 4-3. 한 번에 푸시

```bash
# 각 서비스 레포에서
git add .
git commit -m "feat: complete [service] with CI/CD pipeline"
git push origin main

# → GitHub Actions 자동 실행
# → ECR에 이미지 푸시됨
```

---

## Step 5. 자동화된 배포 흐름

### 5-1. CI 자동 실행 확인

각 서비스 레포의 **Actions** 탭:

```
✅ Build and Push image:  frontend / backend / ai
   ↓
   ECR에 이미지 푸시 (태그: github.sha)
```

### 5-2. 이미지 태그 업데이트 (수동 또는 자동)

#### **방법 A: 수동 업데이트 (간단함)**

```bash
cd medical-service-infra

# 현재 ECR 이미지 확인
aws ecr describe-images \
  --repository-name medical-service-frontend \
  --region ap-northeast-2 \
  --query 'imageDetails[0].[imageTags,imagePushedAt]'

# k8s/overlays/prod/kustomization.yaml 수정
# images[].newTag 를 위 commit SHA로 업데이트

# 커밋 & 푸시
git add k8s/overlays/prod/kustomization.yaml
git commit -m "ci: update image tags to latest"
git push origin main

# ArgoCD가 자동으로 감지해서 배포
```

#### **방법 B: 워크플로우 자동 업데이트 (후속 개선)**

각 서비스 CI에 아래 로직 추가 (EKS 설치 후):

```yaml
- name: Update infra kustomization
  # ... GitHub 토큰으로 infra repo 접근
  # ... YAML 파일 자동 수정
  # ... PR 자동 생성
```

### 5-3. ArgoCD 동기화 확인

```bash
# ArgoCD 상태 확인
kubectl get application medical-service -n argocd

# 상세 보기
kubectl describe application medical-service -n argocd

# 배포된 Pod 확인
kubectl get pods
kubectl logs deployment/frontend
kubectl logs deployment/backend
kubectl logs deployment/ai
```

**예상 상태:**
```
NAME              SYNC STATUS   HEALTH STATUS
medical-service   Synced        Healthy
```

### 5-4. 서비스 접근

```bash
# 각 서비스의 로드 밸런서 주소 확인
kubectl get svc

# 예시:
# frontend-service   LoadBalancer   10.0.1.1   a1b2c3d4-123456.ap-northeast-2.elb.amazonaws.com:80

# 브라우저에서 접근
# http://a1b2c3d4-123456.ap-northeast-2.elb.amazonaws.com
```

---

## 전체 흐름 요약

```
개발 완료 (AI + Backend + Frontend)
    ↓
워크플로우 + 코드 한 번에 푸시
    ↓
GitHub Actions 자동 실행
    ↓
Docker 이미지 빌드 & ECR 푸시
    ↓
이미지 태그 수동 업데이트
(또는 PR 자동 생성)
    ↓
medical-service-infra main 푸시
    ↓
ArgoCD 감지
    ↓
Kubernetes 배포 (롤링 업데이트)
    ↓
서비스 Live 🎉
```

---

## 체크리스트

### 배포 직전

- [ ] EKS 클러스터 생성 완료
- [ ] kubeconfig 연결 확인
- [ ] DB Secret 생성 완료
- [ ] ArgoCD 설치 및 Application 생성 완료
- [ ] GitHub 레포 연결 확인

### 서비스 배포

- [ ] AI 개발 완료 + 정확도 확인
- [ ] 백엔드 개발 완료 + 로컬 테스트
- [ ] 프론트엔드 개발 완료 + 백엔드 통신 확인
- [ ] 워크플로우 파일 작성 완료
- [ ] 모든 서비스 코드 + 워크플로우 + Dockerfile 한 번에 푸시
- [ ] GitHub Actions 성공 확인
- [ ] ECR 이미지 푸시 확인
- [ ] kustomization.yaml 업데이트 (수동/자동)
- [ ] ArgoCD 동기화 확인
- [ ] 서비스 접근 확인

---

## 트러블슈팅

### ArgoCD에서 Pod이 Pending 상태

```bash
# Pod 상태 확인
kubectl describe pod [POD_NAME]

# 일반적 원인:
# 1. 이미지가 ECR에 없음 → imagePullBackOff
# 2. 리소스 부족 → Pending
# 3. 노드 문제 → NotSchedulable
```

### 이미지 Pull 실패

```bash
# ECR 로그인 확인
aws ecr describe-repositories --region ap-northeast-2

# ECR Public Access 비활성화 확인
# (프라이빗 레지스트리이므로 IAM 역할 필요)
```

### ArgoCD와 Git 동기화 안 됨

```bash
# ArgoCD Application 상태
kubectl describe application medical-service -n argocd

# ArgoCD 컨트롤러 로그
kubectl logs -n argocd deployment/argocd-application-controller
```

---

**Last Updated**: May 2026  
**순서**: EKS 설치 → ArgoCD → 서비스 배포
