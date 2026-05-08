# Git Clone 후 로컬 개발 및 배포 준비 가이드

> **상태**: 코드 clone 받은 후 → 로컬 테스트 → 배포 준비  
> **대상**: frontend, backend, ai 서비스 개발팀

---

## 📍 현재 상황

```
✅ Git clone 완료 (4개 레포)
✅ AWS 기반 완성 (ECR, VPC, RDS Aurora, GitHub Secrets)
⏳ 각 서비스 로컬 테스트
⏳ 배포 설정 파일 수정
```

---

## Phase 1️⃣: 각 서비스 로컬 Docker 빌드 테스트

### 1-1. AI Service (`ai-medicare`)

#### 구조 확인
```bash
cd ai-medicare

# 파일 확인
ls -la
# Dockerfile
# requirements.txt
# main.py
# model.py
# features.py
# schemas.py
# database.py
```

#### 로컬 빌드 테스트
```bash
# 이미지 빌드
docker build -t medical-service-ai:local .

# 로컬 실행 (포트 8001)
docker run --rm -it \
  -p 8001:8001 \
  -e LOG_LEVEL=DEBUG \
  medical-service-ai:local

# 테스트 (다른 터미널)
curl http://localhost:8001/health
# 예상 응답: {"status": "ok"}
```

**중요 확인 사항:**
- [x] Dockerfile에 `EXPOSE 8001` 있는가?
- [x] `CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8001"]` 있는가?
- [x] requirements.txt 모든 패키지 설치 가능한가?
- [x] 모델 파일 경로 맞는가? (절대경로 X, 상대경로 O)

#### 포트 & 환경 변수
| 항목 | 값 |
|------|-----|
| 포트 | `8001` |
| 헬스 체크 경로 | `/health` |
| 환경 변수 | `LOG_LEVEL=INFO` |
| 백엔드 URL (K8s) | `http://backend-service:80` |

---

### 1-2. Backend Service (`medical-service-backend`)

#### 구조 확인
```bash
cd medical-service-backend

# 파일 구조 확인
tree -I 'node_modules|target'
# Dockerfile
# package.json (또는 pom.xml for Maven)
# src/
```

#### 로컬 빌드 테스트
```bash
# 이미지 빌드
docker build -t medical-service-backend:local .

# 로컬 실행 (포트 3000 또는 8080)
docker run --rm -it \
  -p 3000:3000 \
  -e LOG_LEVEL=DEBUG \
  -e DATABASE_URL="jdbc:mysql://127.0.0.1:3306/medicalservicedb" \
  -e DB_USERNAME=admin \
  -e DB_PASSWORD=password \
  -e AI_BASE_URL=http://host.docker.internal:8001 \
  medical-service-backend:local

# 테스트 (다른 터미널)
curl http://localhost:3000/health
# 예상 응답: {"status": "ok"}
```

**중요 확인 사항:**
- [x] Dockerfile에 `EXPOSE 3000` (또는 8080) 있는가?
- [x] 모든 npm/maven 의존성 설치 가능한가?
- [x] DB 커넥션 문자열 포맷 맞는가? (MySQL 또는 PostgreSQL)
- [x] AI 서비스 통신 경로 설정 가능한가?

#### 포트 & 환경 변수
| 항목 | 값 |
|------|-----|
| 포트 | `3000` |
| 헬스 체크 경로 | `/health` |
| 환경 변수 | `LOG_LEVEL=INFO`, `DB_USERNAME=admin`, `DB_PASSWORD=password` |
| DB URL (K8s) | `jdbc:mysql://medical-service-aurora.xxxxx.ap-northeast-2.rds.amazonaws.com:3306/medicalservicedb` |
| AI URL (K8s) | `http://ai-service:80` |

---

### 1-3. Frontend Service (`medical-service-frontend`)

#### 구조 확인
```bash
cd medical-service-frontend

# 파일 구조
ls -la
# Dockerfile
# nginx.conf
# package.json
# src/
# public/
```

#### 로컬 빌드 테스트
```bash
# 이미지 빌드
docker build -t medical-service-frontend:local .

# 로컬 실행 (포트 8080 또는 80)
docker run --rm -it \
  -p 8080:80 \
  medical-service-frontend:local

# 테스트 (브라우저 또는 curl)
curl http://localhost:8080
# 또는 브라우저: http://localhost:8080
```

**중요 확인 사항:**
- [x] Dockerfile에 `EXPOSE 80` 있는가?
- [x] nginx.conf에 백엔드 API URL 설정 있는가?
- [x] 모든 npm 의존성 설치 가능한가?
- [x] 빌드 후 정적 파일 생성 확인 가능한가? (dist/ 또는 build/)

#### 포트 & 환경 변수
| 항목 | 값 |
|------|-----|
| 포트 | `80` |
| 서빙 경로 | `nginx` |
| API Base URL (K8s) | `http://backend-service` |

---

## Phase 2️⃣: 로컬 Docker Compose 통합 테스트

### 2-1. docker-compose.yml 설정 확인

```yaml
# 위치: 프로젝트 루트 또는 medical-service-infra/
# 파일명: docker-compose.yml

version: '3.8'

services:
  ai:
    build:
      context: ./ai-medicare
      dockerfile: Dockerfile
    container_name: ai-service
    ports:
      - "8001:8001"
    environment:
      - LOG_LEVEL=DEBUG
    networks:
      - medical-network
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8001/health"]
      interval: 10s
      timeout: 5s
      retries: 5

  backend:
    build:
      context: ./medical-service-backend
      dockerfile: Dockerfile
    container_name: backend-service
    ports:
      - "3000:3000"
    environment:
      - LOG_LEVEL=DEBUG
      - DATABASE_URL=jdbc:mysql://mysql:3306/medicalservicedb
      - DB_USERNAME=admin
      - DB_PASSWORD=rootpassword
      - AI_BASE_URL=http://ai:8001
    depends_on:
      - mysql
      - ai
    networks:
      - medical-network
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:3000/health"]
      interval: 10s
      timeout: 5s
      retries: 5

  frontend:
    build:
      context: ./medical-service-frontend
      dockerfile: Dockerfile
    container_name: frontend-service
    ports:
      - "8080:80"
    environment:
      - REACT_APP_API_URL=http://localhost:3000
    depends_on:
      - backend
    networks:
      - medical-network

  mysql:
    image: mysql:8.0
    container_name: mysql-db
    environment:
      - MYSQL_ROOT_PASSWORD=rootpassword
      - MYSQL_DATABASE=medicalservicedb
      - MYSQL_USER=admin
      - MYSQL_PASSWORD=rootpassword
    ports:
      - "3306:3306"
    volumes:
      - mysql_data:/var/lib/mysql
    networks:
      - medical-network
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-h", "localhost"]
      interval: 10s
      timeout: 5s
      retries: 5

networks:
  medical-network:
    driver: bridge

volumes:
  mysql_data:
```

### 2-2. 로컬 통합 테스트 실행

```bash
# 프로젝트 루트에서
docker-compose up -d

# 상태 확인
docker-compose ps
# 예상: 4개 컨테이너 모두 Up 상태

# 로그 확인
docker-compose logs -f

# 각 서비스 테스트
curl http://localhost:8001/health  # AI
curl http://localhost:3000/health  # Backend
curl http://localhost:8080         # Frontend (브라우저도 가능)

# 종료
docker-compose down
```

---

## Phase 3️⃣: 배포 설정 파일 수정 (나중에 할 것)

### 3-1. ArgoCD Application 수정

**파일 경로**: `medical-service-infra/argocd/application.yaml`

#### 현재 상태
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: medical-service
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/YOUR_ORG/medical-service-infra.git  # ← 변경 필요
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

#### 수정 필요 항목
| 항목 | 현재값 | 변경값 | 시점 |
|------|--------|--------|------|
| `repoURL` | `YOUR_ORG` | 실제 GitHub Org | EKS 설치 후 |
| `namespace` | `default` | 원하면 변경 (optional) | EKS 설치 후 |

---

### 3-2. k8s/overlays/prod/kustomization.yaml 수정

**파일 경로**: `medical-service-infra/k8s/overlays/prod/kustomization.yaml`

#### 현재 상태
```yaml
namespace: medical-service  # ← 맞는지 확인

configMapGenerator:
  - name: app-config
    behavior: merge
    literals:
      - LOG_LEVEL=INFO
      - AI_BASE_URL=http://ai-service:80           # ← 서비스명 확인
      - BACKEND_API_URL=http://backend-service:80  # ← 서비스명 확인
      - FRONTEND_API_BASE=http://backend-service:80

images:
  - name: medical-service-frontend
    newName: 296336226405.dkr.ecr.ap-northeast-2.amazonaws.com/medical-service-frontend
    newTag: "latest"  # ← 배포시 변경: sha-xxxxx

  - name: medical-service-backend
    newName: 296336226405.dkr.ecr.ap-northeast-2.amazonaws.com/medical-service-backend
    newTag: "latest"  # ← 배포시 변경: sha-xxxxx

  - name: medical-service-ai
    newName: 296336226405.dkr.ecr.ap-northeast-2.amazonaws.com/medical-service-ai
    newTag: "latest"  # ← 배포시 변경: sha-xxxxx

replicas:
  - name: frontend
    count: 2
  - name: backend
    count: 2
  - name: ai
    count: 2

patchesStrategicMerge:
  - apiVersion: networking.k8s.io/v1
    kind: Ingress
    metadata:
      name: medical-ingress
    spec:
      rules:
        - host: "YOUR_DOMAIN.com"  # ← 배포시 변경: 실제 도메인
          http:
            paths:
              - path: /
                pathType: Prefix
                backend:
                  service:
                    name: backend-service
                    port:
                      number: 80
```

#### 수정 필요 항목 (배포시)
| 항목 | 현재값 | 변경값 | 시점 |
|------|--------|--------|------|
| `namespace` | `medical-service` | 유지 | - |
| `AI_BASE_URL` | `http://ai-service:80` | 서비스명 확인 | CI/CD 후 |
| `BACKEND_API_URL` | `http://backend-service:80` | 서비스명 확인 | CI/CD 후 |
| `images[].newTag` | `latest` | `sha-a1b2c3d4` | 빌드 후 |
| `replicas` | 각 2개 | 필요시 조정 | 배포 후 |
| `YOUR_DOMAIN.com` | placeholder | 실제 도메인/LB 주소 | 배포 후 |

---

### 3-3. k8s/base/ 매니페스트 파일 확인 & 수정

#### Frontend Deployment
**파일**: `medical-service-infra/k8s/base/frontend-deployment.yaml`

```yaml
# 확인 사항:
# - containerPort: 80 (Dockerfile EXPOSE와 일치)
# - image: medical-service-frontend (k8s/base/kustomization.yaml의 images.name과 일치)
# - livenessProbe.httpGet.path: / (또는 실제 health 경로)
# - resources.limits/requests 적절한가?
```

**수정 필요 항목:**
```yaml
containers:
  - name: frontend
    image: medical-service-frontend  # ← k8s base에서는 placeholder, prod overlay에서 ECR URI로 대체
    ports:
      - containerPort: 80           # ← Dockerfile EXPOSE와 일치하는지 확인
    env:
      - name: REACT_APP_API_URL
        value: "http://backend-service"  # ← 백엔드 서비스명 확인
    livenessProbe:
      httpGet:
        path: /                      # ← 실제 health 경로로 변경 가능
        port: 80
    resources:
      requests:
        memory: "128Mi"
        cpu: "100m"
      limits:
        memory: "256Mi"
        cpu: "500m"
```

#### Backend Deployment
**파일**: `medical-service-infra/k8s/base/backend-deployment.yaml`

```yaml
# 확인 사항:
# - containerPort: 3000 (또는 8080) - Dockerfile EXPOSE와 일치
# - 환경 변수: DATABASE_URL, DB_USERNAME, DB_PASSWORD, AI_BASE_URL
# - Secret 참조: db-credentials (EKS에서 수동 생성)
```

**수정 필요 항목:**
```yaml
containers:
  - name: backend
    image: medical-service-backend
    ports:
      - containerPort: 3000         # ← Dockerfile EXPOSE와 일치하는지 확인
    env:
      - name: DATABASE_URL
        value: "jdbc:mysql://medical-service-aurora.xxxxx.ap-northeast-2.rds.amazonaws.com:3306/medicalservicedb"  # ← Terraform output 입력
      - name: DB_USERNAME
        valueFrom:
          secretKeyRef:
            name: db-credentials
            key: DB_USERNAME
      - name: DB_PASSWORD
        valueFrom:
          secretKeyRef:
            name: db-credentials
            key: DB_PASSWORD
      - name: AI_BASE_URL
        value: "http://ai-service:80"  # ← 서비스명 확인
    resources:
      requests:
        memory: "512Mi"
        cpu: "250m"
      limits:
        memory: "1Gi"
        cpu: "1000m"
```

#### AI Deployment
**파일**: `medical-service-infra/k8s/base/ai-deployment.yaml`

```yaml
# 확인 사항:
# - containerPort: 8001 - Dockerfile EXPOSE와 일치
# - 환경 변수: LOG_LEVEL, BACKEND_API_URL
```

**수정 필요 항목:**
```yaml
containers:
  - name: ai
    image: medical-service-ai
    ports:
      - containerPort: 8001         # ← Dockerfile EXPOSE와 일치하는지 확인
    env:
      - name: LOG_LEVEL
        value: "INFO"
      - name: BACKEND_API_URL
        value: "http://backend-service:80"  # ← 백엔드 서비스명 확인
    resources:
      requests:
        memory: "256Mi"
        cpu: "100m"
      limits:
        memory: "1Gi"
        cpu: "1000m"
```

---

### 3-4. k8s/base/secret.yaml (절대 commit하지 말 것!)

**파일**: `medical-service-infra/k8s/base/secret.yaml`

⚠️ **중요**: 이 파일은 **EKS 배포시 사용하지 말 것**. 대신 `kubectl create secret` 명령으로 직접 생성:

```bash
# EKS 배포 직전 실행
RDS_ENDPOINT="medical-service-aurora.xxxxx.ap-northeast-2.rds.amazonaws.com"

kubectl create secret generic db-credentials \
  --namespace default \
  --from-literal=DB_USERNAME=admin \
  --from-literal=DB_PASSWORD='실제_비밀번호' \
  --from-literal=DATABASE_URL="jdbc:mysql://admin:실제_비밀번호@${RDS_ENDPOINT}:3306/medicalservicedb" \
  -o yaml > /tmp/secret.yaml

# 확인 (파일에 실제 값이 base64로 저장됨 - 절대 GitHub에 commit X)
cat /tmp/secret.yaml
```

---

### 3-5. Service 파일 확인

**파일들**: `medical-service-infra/k8s/base/service.yaml`, `ai-service.yaml` 등

```yaml
# 확인 사항 - Frontend Service
apiVersion: v1
kind: Service
metadata:
  name: frontend-service  # ← deployment와 selector 일치
spec:
  type: LoadBalancer      # ← 또는 ClusterIP/NodePort
  ports:
    - port: 80            # ← 외부 포트
      targetPort: 80      # ← Pod 내부 포트 (Dockerfile EXPOSE와 일치)
  selector:
    app: frontend         # ← deployment의 labels와 일치

---

# 확인 사항 - Backend Service
apiVersion: v1
kind: Service
metadata:
  name: backend-service
spec:
  type: ClusterIP         # ← 내부 통신만
  ports:
    - port: 80            # ← Pod 내부에서 접근시 사용
      targetPort: 3000    # ← Pod의 실제 포트
  selector:
    app: backend

---

# 확인 사항 - AI Service
apiVersion: v1
kind: Service
metadata:
  name: ai-service
spec:
  type: ClusterIP
  ports:
    - port: 80
      targetPort: 8001    # ← Pod의 실제 포트
  selector:
    app: ai
```

---

## 📋 체크리스트 (로컬 테스트 완료 후)

### ✅ Docker 빌드
- [ ] AI 이미지 빌드 성공
- [ ] Backend 이미지 빌드 성공
- [ ] Frontend 이미지 빌드 성공

### ✅ 개별 실행
- [ ] AI 서비스 포트 8001 응답 확인
- [ ] Backend 서비스 포트 3000 응답 확인
- [ ] Frontend 서비스 포트 80 응답 확인

### ✅ Docker Compose 통합
- [ ] 4개 컨테이너 모두 Up 상태
- [ ] AI ↔ Backend 통신 확인
- [ ] Frontend ↔ Backend 통신 확인
- [ ] MySQL 데이터베이스 연결 확인

### ✅ 배포 준비 파일
- [ ] ArgoCD application.yaml 검토
- [ ] k8s/overlays/prod/kustomization.yaml 검토
- [ ] k8s/base/*.yaml 파일 포트 & 서비스명 확인
- [ ] Secret 생성 명령어 기록해두기

---

## 🚀 다음 단계

1. **로컬 테스트 완료** → 이 문서 체크리스트 모두 확인
2. **코드 푸시** → 워크플로우 + Dockerfile + 서비스 코드 한 번에
3. **GitHub Actions 실행** → ECR 이미지 푸시
4. **EKS 배포** → AFTER_EKS.md 참고

---

**Last Updated**: May 2026  
**상태**: 개발 중 → 배포 준비
