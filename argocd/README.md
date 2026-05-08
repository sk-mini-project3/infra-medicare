# ArgoCD 설치 및 적용 가이드

## 1. ArgoCD 네임스페이스 및 설치

```bash
# ArgoCD 네임스페이스 생성
kubectl create namespace argocd

# ArgoCD 설치 (stable 버전)
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Pod 대기 (2~3분)
kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=argocd-server -n argocd --timeout=300s
```

## 2. GitHub 레포 연결 설정

### 공개 레포인 경우
- ArgoCD 웹 UI에서 Settings → Repositories → Connect Repo
- HTTPS 방식 선택, 레포 URL 입력
- 자동으로 연결됨

### 개인 (프라이빗) 레포인 경우
- GitHub PAT (Personal Access Token) 필요
- 권한: `repo`, `read:org`

```bash
# Kubernetes Secret으로 GitHub credentials 등록
kubectl create secret generic github-credentials \
  -n argocd \
  --from-literal=username=YOUR_GITHUB_USERNAME \
  --from-literal=password=YOUR_GITHUB_PAT \
  --from-literal=url=https://github.com
```

## 3. ArgoCD 접근

### 초기 관리자 비밀번호 확인
```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d
```

### 로컬에서 접근
```bash
# Port forward (8080은 충돌 가능하면 다른 포트로 변경)
kubectl port-forward svc/argocd-server -n argocd 8080:443

# 브라우저에서 접속
# https://localhost:8080
# Username: admin
# Password: [위에서 확인한 값]
```

### AWS 환경에서 접근 (운영)
- ALB (Application Load Balancer) 설정
- Route53 도메인 연결
- SSL/TLS 인증서 설정

## 4. Application 배포

```bash
# ArgoCD Application 생성 (Git에서 관리)
kubectl apply -f argocd/application.yaml

# 또는 ArgoCD CLI 사용
argocd app create medical-service \
  --repo https://github.com/YOUR_ORG/infra-medicare.git \
  --path k8s/overlays/prod \
  --dest-server https://kubernetes.default.svc \
  --dest-namespace default
```

## 5. 배포 상태 확인

```bash
# ArgoCD CLI
argocd app get medical-service
argocd app list
argocd app wait medical-service

# Kubectl로 확인
kubectl get application -n argocd
kubectl describe application medical-service -n argocd

# Kubernetes 리소스 확인
kubectl get deployments
kubectl get pods
kubectl get services
```

## 6. 주의사항

- **초기 비밀번호 변경**: 프로덕션 환경에서는 반드시 변경
- **RBAC 설정**: 필요에 따라 ArgoCD RBAC 규칙 설정
- **Webhook 설정**: GitHub Push 이벤트 시 자동 동기화 (선택사항)
- **모니터링**: Prometheus + Grafana로 ArgoCD 메트릭 수집 가능

## 7. 배포 워크플로우

```
1. 개발자가 코드 커밋 → infra-medicare main 브랜치
2. GitHub Actions로 이미지 빌드/푸시 (ECR)
3. 이미지 태그로 kustomization.yaml 업데이트 (infra-medicare)
4. ArgoCD가 Git 변경 감지
5. ArgoCD가 자동으로 EKS에 배포 (sync)
6. 애플리케이션 자동 배포
```

## 8. Troubleshooting

### Application이 OutOfSync 상태
```bash
# 수동으로 동기화
argocd app sync medical-service

# 또는 ArgoCD UI에서 "SYNC" 버튼 클릭
```

### Pod가 계속 Pending
```bash
kubectl describe pod [POD_NAME]
# 리소스 부족, 이미지 pull 실패 등 확인
```

### 이미지를 받아오지 못함 (ImagePullBackOff)
```bash
# ECR 접근 권한 확인
# EKS 노드의 IAM 역할에 ECR 권한이 있는지 확인

# ECR 로그인 시크릿 생성 (필요시)
kubectl create secret docker-registry ecr-credentials \
  --docker-server=296336226405.dkr.ecr.ap-northeast-2.amazonaws.com \
  --docker-username=AWS \
  --docker-password=$(aws ecr get-login-password --region ap-northeast-2) \
  --docker-email=user@example.com
```
