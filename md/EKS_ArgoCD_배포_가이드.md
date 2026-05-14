# Medicare 서비스 EKS 설치 → Argo CD 배포까지 (순서 가이드)

현재 상태(EC2 + ALB + GHCR 운영 완료)를 전제로, **인프라용 GitHub 레포는 이미 있다**고 가정하고 **EKS 클러스터 생성부터 Argo CD로 GitOps 배포**까지 한 줄씩 따라 할 수 있게 정리했습니다.

이 프로젝트의 인프라 매니페스트는 보통 아래와 같은 구조입니다(레포 루트 기준).

- `k8s/base/` … Deployment, Service, Ingress 공통
- `k8s/overlays/prod/` … 운영용 Kustomize (`namespace: medical-prod`, 이미지 태그, ConfigMap/Secret 생성)
- `k8s/overlays/dev/` … 개발용
- `argocd/application.yaml` … Argo CD Application 정의
- 레포 루트 … `medical-backend.env`, `medical-ai.env` (prod overlay의 `secretGenerator`가 참조)

> **변수 치환**: 아래에서 `CLUSTER_NAME`, `AWS_REGION`, `INFRA_REPO_URL` 등은 본인 환경 값으로 바꿉니다.

---

## 0. 전제 조건

- AWS 계정, 결제/권한이 있는 IAM 사용자 또는 역할
- VPC에 **퍼블릭 서브넷 2개 이상**, **프라이빗 서브넷 2개 이상** 권장(노드는 프라이빗, ALB는 퍼블릭)
- 이미지는 **GHCR**에 푸시되어 있음 (`read:packages` 가능한 토큰)
- 인프라 레포에 위 `k8s/`, `argocd/` 및 `.env` 파일이 **커밋되어** Argo CD가 읽을 수 있음  
  (비밀번호 등 민감값은 Git에 올리지 않는 방식이 이상적이나, 현재 구조는 Kustomize `secretGenerator`로 `.env`를 빌드에 포함합니다. 운영에서는 External Secrets 등으로 옮기는 것을 권장합니다.)

---

## 1. 로컬 도구 설치 및 AWS CLI 설정

### 1-1. 설치할 것

- [AWS CLI](https://aws.amazon.com/cli/)
- [kubectl](https://kubernetes.io/docs/tasks/tools/)
- [eksctl](https://eksctl.io/installation/)
- [Helm](https://helm.sh/docs/intro/install/)

### 1-2. AWS 자격 증명

```bash
aws configure
aws sts get-caller-identity
```

계정 ID가 출력되면 정상입니다.

---

## 2. EKS 클러스터 생성 (eksctl)

### 2-1. 환경 변수

```bash
export AWS_REGION=ap-northeast-2
export CLUSTER_NAME=medical-eks-prod
```

Windows PowerShell이면:

```powershell
$env:AWS_REGION = "ap-northeast-2"
$env:CLUSTER_NAME = "medical-eks-prod"
```

### 2-2. 클러스터 + 관리형 노드 그룹 생성

최소 예시(운영 부하에 맞게 노드 타입/개수 조정):

```bash
eksctl create cluster \
  --name "${CLUSTER_NAME}" \
  --region "${AWS_REGION}" \
  --version 1.30 \
  --nodegroup-name main-ng \
  --node-type t3.large \
  --nodes 2 \
  --nodes-min 2 \
  --nodes-max 6 \
  --managed
```

생성에는 **20~40분** 정도 걸릴 수 있습니다.

### 2-3. kubeconfig 연결

```bash
aws eks update-kubeconfig --region "${AWS_REGION}" --name "${CLUSTER_NAME}"
kubectl get nodes
```

모든 노드가 `Ready`이면 다음 단계로 진행합니다.

---

## 3. ALB용 서브넷 태그 (중요)

AWS Load Balancer Controller가 ALB를 만들려면, **ALB가 붙을 서브넷**(보통 퍼블릭)에 태그가 필요합니다.

- `kubernetes.io/cluster/${CLUSTER_NAME}` = `shared` (또는 `owned`)
- 퍼블릭 ALB용: `kubernetes.io/role/elb` = `1`

`eksctl`로 만든 VPC/서브넷은 종종 이미 맞춰져 있지만, **기존 VPC를 가져다 쓴 경우** 콘솔에서 서브넷 태그를 반드시 확인하세요.

---

## 4. AWS Load Balancer Controller 설치

공식 문서와 버전은 시기에 따라 바뀌므로, **[Installing the AWS Load Balancer Controller](https://docs.aws.amazon.com/eks/latest/userguide/aws-load-balancer-controller.html)** 를 열어 두고 진행하는 것을 권장합니다.

### 4-1. OIDC 공급자 연결

```bash
eksctl utils associate-iam-oidc-provider \
  --region "${AWS_REGION}" \
  --cluster "${CLUSTER_NAME}" \
  --approve
```

### 4-2. IAM 정책 생성

문서에 나온 **최신** `iam_policy.json` URL로 다운로드한 뒤:

```bash
aws iam create-policy \
  --policy-name AWSLoadBalancerControllerIAMPolicy \
  --policy-document file://iam_policy.json
```

출력된 `Arn`을 메모합니다. 이미 같은 이름 정책이 있으면 해당 `Arn`을 사용합니다.

### 4-3. IRSA(서비스 계정용 IAM 역할) 생성

문서의 `eksctl create iamserviceaccount` 예시를 그대로 사용하되, `--cluster`, `--region`, `--attach-policy-arn`만 본인 값으로 맞춥니다.

핵심은 `kube-system` 네임스페이스에 **`aws-load-balancer-controller`** 서비스 계정이 생기고, 그 역할에 위 IAM 정책이 붙는 것입니다.

### 4-4. Helm으로 Controller 설치

```bash
helm repo add eks https://aws.github.io/eks-charts
helm repo update
```

클러스터의 **VPC ID**는 다음으로 확인합니다.

```bash
aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${AWS_REGION}" \
  --query "cluster.resourcesVpcConfig.vpcId" --output text
```

Helm 설치(문서 예시와 동일하게, `clusterName` / `region` / `vpcId` / 서비스 계정 이름 맞춤):

```bash
helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName="${CLUSTER_NAME}" \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set region="${AWS_REGION}" \
  --set vpcId=<VPC_ID>
```

### 4-5. 동작 확인

```bash
kubectl -n kube-system get deployment aws-load-balancer-controller
kubectl -n kube-system get pods -l app.kubernetes.io/name=aws-load-balancer-controller
```

---

## 5. IngressClass `alb` 확인

매니페스트의 Ingress는 **`spec.ingressClassName: alb`** 를 사용합니다. Controller 설치 후:

```bash
kubectl get ingressclass
```

`alb`가 보이면 됩니다. 없으면 Helm chart 옵션 또는 설치 문서에서 IngressClass 생성 여부를 확인하세요.

---

## 6. 인프라 GitHub 레포 준비 (이미 생성된 경우)

레포 루트에 대략 다음이 있어야 Argo CD 한 방에 동기화됩니다.

| 경로 | 역할 |
|------|------|
| `k8s/base/` | 프론트/백엔드/AI Deployment·Service·Ingress |
| `k8s/overlays/prod/kustomization.yaml` | prod 네임스페이스, 이미지, ConfigMap/Secret 생성 |
| `argocd/application.yaml` | Argo CD Application |
| `medical-backend.env` | 백엔드용 env (Kustomize secretGenerator) |
| `medical-ai.env` | AI용 env |

**반드시 수정할 값(예시)**

- `k8s/overlays/prod/kustomization.yaml`의 `images:` … `ghcr.io/<본인조직>/...` 및 이미지 태그
- 같은 파일의 `configMapGenerator` … `NEXT_PUBLIC_API_URL`, `APP_FRONTEND_URL`, `AI_BASE_URL` (실제 도메인 또는 ALB DNS 확정 후)
- `argocd/application.yaml`의 `repoURL` … 본인 인프라 레포 HTTPS URL
- `targetRevision` … 실제 브랜치명(`main` 등)

커밋 후 원격에 푸시합니다.

---

## 7. 운영 네임스페이스 `medical-prod` 및 GHCR Pull Secret

Argo CD가 `CreateNamespace=true`로 `medical-prod`를 만들 수도 있지만, **이미지 Pull Secret은 Argo가 자동 생성하지 않으므로** 미리 만드는 편이 안전합니다.

### 7-1. 네임스페이스

```bash
kubectl create namespace medical-prod
```

(이미 Argo가 만들었다면 생략.)

### 7-2. GHCR용 `docker-registry` Secret

GitHub PAT에 **`read:packages`** 권한이 있어야 합니다.

```bash
kubectl create secret docker-registry ghcr-secret \
  --docker-server=ghcr.io \
  --docker-username=<GITHUB_USER_OR_BOT> \
  --docker-password=<GITHUB_PAT> \
  --docker-email=<EMAIL> \
  -n medical-prod
```

매니페스트의 Deployment는 `imagePullSecrets: ghcr-secret`을 참조합니다.

---

## 8. 로컬에서 Kustomize 빌드 검증 (선택, 권장)

`prod` overlay는 레포 루트의 `.env`를 참조하므로, 로컬 빌드 시 **로드 제한 해제**가 필요합니다.

```bash
cd <인프라_레포_클론_경로>
kubectl kustomize k8s/overlays/prod --load-restrictor LoadRestrictionsNone | head -n 80
```

에러 없이 YAML이 쏟아지면 Argo CD 쪽 Kustomize도 통과할 가능성이 큽니다.  
(인프라 레포의 `application.yaml`에는 동일 목적으로 `kustomize.buildOptions`가 들어가 있습니다.)

---

## 9. Argo CD 설치

### 9-1. 네임스페이스 및 매니페스트 적용

```bash
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
```

### 9-2. Pod 준비 대기

```bash
kubectl -n argocd wait --for=condition=Ready pod -l app.kubernetes.io/name=argocd-server --timeout=300s
```

### 9-3. 초기 admin 비밀번호

Linux / macOS:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d
echo
```

Windows PowerShell:

```powershell
[System.Text.Encoding]::UTF8.GetString(
  [System.Convert]::FromBase64String(
    (kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}')
  )
)
```

### 9-4. UI 접속(임시)

```bash
kubectl port-forward svc/argocd-server -n argocd 8081:443
```

브라우저에서 `https://localhost:8081` (자체 서명 TLS 경고 무시), 사용자 `admin`, 위 비밀번호로 로그인합니다.

---

## 10. Argo CD에 Git 레포지토리 연결

### 10-1. 공개 레포

UI에서 **Settings → Repositories → Connect Repo** 로 HTTPS URL만 등록하면 됩니다.

### 10-2. 비공개 레포

PAT(`repo` 읽기 등)로 Argo CD에 자격 증명을 등록합니다. (조직 정책에 맞게 선택)

```bash
kubectl create secret generic infra-repo-creds \
  -n argocd \
  --from-literal=type=git \
  --from-literal=url=https://github.com/<ORG>/<INFRA_REPO>.git \
  --from-literal=username=git \
  --from-literal=password=<GITHUB_PAT>
```

레포 타입 시크릿으로 라벨을 붙이는 방식은 [Argo CD 문서](https://argo-cd.readthedocs.io/en/stable/operator-manual/declarative-setup/#repositories)를 따릅니다.

---

## 11. Application 등록 (클러스터에 적용)

인프라 레포의 `argocd/application.yaml`을 사용합니다. 내용 요지는 다음과 같습니다.

- `path: k8s/overlays/prod`
- `destination.namespace: medical-prod`
- `syncPolicy.automated` + `CreateNamespace=true`
- `kustomize.buildOptions: --load-restrictor LoadRestrictionsNone` (레포 루트 `.env` 참조용)

### 11-1. 레포에서 파일 적용

인프라 레포를 클론한 뒤:

```bash
kubectl apply -f argocd/application.yaml
```

### 11-2. 상태 확인

```bash
kubectl -n argocd get applications
kubectl -n argocd describe application medical-service
```

UI에서도 **Applications → medical-service** 로 들어가 `Synced` / `Healthy`를 확인합니다.

처음에는 **OutOfSync**일 수 있으므로 **Sync** 한 번 실행해도 됩니다.

---

## 12. 배포 후 리소스·Ingress 확인

```bash
kubectl -n medical-prod get deployments,pods,svc,ingress
```

Ingress에 **ALB 호스트명**이 붙을 때까지 1~3분 정도 걸릴 수 있습니다.

```bash
kubectl -n medical-prod get ingress medical-ingress -o wide
```

현재 Ingress 라우팅 예시는 다음과 같습니다.

- `/` → 프론트 Service
- `/api` → 백엔드 Service
- `/ai` → AI Service

ALB DNS가 나오면, 브라우저 또는 `curl`로 접속해 봅니다.  
그다음 **백엔드·메일·CORS**에 쓰이는 URL이 EC2 시절 ALB를 가리키고 있으면, `medical-backend.env` 또는 `k8s/overlays/prod`의 ConfigMap 값을 **새 EKS ALB(또는 도메인)** 기준으로 수정하고 커밋하면 Argo가 다시 배포합니다.

---

## 13. RDS / Redis / EKS 네트워크

- **RDS**: EKS 노드(또는 Pod가 나가는 보안 그룹)에서 RDS 보안 그룹으로 **3306** 허용
- **ElastiCache Redis**: 동일하게 **6379** 허용 (기존 EC2 때와 동일한 패턴이면 SG만 노드 쪽으로 확장)
- 백엔드 `SPRING_DATASOURCE_URL`, `REDIS_HOST` 등은 `.env` 또는 ConfigMap과 일치하는지 확인

---

## 14. CI/CD와 GitOps (배포 루프)

1. 앱 레포 CI: 이미지 빌드 후 **GHCR 푸시** (태그는 커밋 SHA 권장)
2. 인프라 레포: `k8s/overlays/prod/kustomization.yaml`의 `images.newTag` (또는 `newName`)를 새 태그로 수정 후 **푸시**
3. Argo CD: 자동 동기화로 Deployment 롤링 업데이트

운영 원칙은 **클러스터에서 직접 `kubectl set image` 하지 않고**, **Git 변경이 곧 배포**가 되게 하는 것입니다.

---

## 15. 체크리스트

- [ ] `kubectl get nodes` → Ready
- [ ] `aws-load-balancer-controller` Pod 정상
- [ ] `kubectl get ingressclass` → `alb`
- [ ] `medical-prod`에 `ghcr-secret` 존재
- [ ] Argo Application `Synced` / `Healthy`
- [ ] `kubectl -n medical-prod get pods` → Running, 재시작 과다 없음
- [ ] ALB 타깃 그룹 **Healthy**
- [ ] 프론트·로그인, 백엔드 API, AI `GET /ai/alerts` **200**

---

## 16. 자주 막히는 곳

| 증상 | 점검 |
|------|------|
| Argo `Kustomize build failed: ... load restrictor` | `application.yaml`의 `kustomize.buildOptions` 또는 로컬에서 `--load-restrictor LoadRestrictionsNone` |
| `ImagePullBackOff` | `ghcr-secret`, PAT 권한, 이미지 경로/태그 |
| Ingress에 주소 없음 | 서브넷 태그, LB Controller 로그, `kubectl describe ingress` |
| 타깃 Unhealthy | 컨테이너 포트·Service `targetPort`·헬스 프로브·보안 그룹 |
| DB 연결 실패 | RDS SG 인바운드에 EKS 노드(또는 클러스터 SG) 추가 |

---

## 17. 한 페이지 요약 순서

1. **도구 설치** + `aws configure`
2. **eksctl로 EKS 생성** + `update-kubeconfig`
3. **서브넷 태그** 확인
4. **AWS Load Balancer Controller** (OIDC → IAM → Helm)
5. **`IngressClass alb`** 확인
6. **인프라 레포**에 이미지·URL·`repoURL` 반영 후 푸시
7. **`medical-prod` + `ghcr-secret`** 생성
8. **Argo CD 설치** → UI/비밀번호 확인
9. **Git 레포 연결** (공개/비공개)
10. **`kubectl apply -f argocd/application.yaml`**
11. **Sync** 후 Pod·Ingress·ALB·앱 동작 확인
12. **RDS/Redis SG** 및 **공개 URL**을 `.env`/ConfigMap에 맞게 정리

이 순서대로 진행하면 **EKS 설치부터 Argo CD 기반 배포**까지 한 사이클을 완료할 수 있습니다.
