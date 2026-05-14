#!/usr/bin/env bash
#
# Default VPC에 EC2 1대 + ALB(HTTP:80 → EC2:3000)를 AWS CLI로 생성합니다.
# 프론트 GitHub Variable NEXT_PUBLIC_API_URL 에 넣을 값은:
#   http://<ALB_DNS>
#
# 사전 조건
#   - aws CLI 로그인·권한 (ec2, elbv2) — WSL만 쓰는데 Windows에 CLI가 있으면
#     기본 설치 경로(Program Files/Amazon/AWSCLIV2/aws.exe)를 자동 사용합니다.
#   - 기본 VPC가 없으면: 2개 이상 AZ에 서브넷이 있는 첫 VPC를 쓰거나,
#     export VPC_ID_OVERRIDE=vpc-xxx 로 지정
#   - EC2 SSH용 키 페어가 해당 리전에 있음
#
# 사용 (Git Bash / WSL / Linux):
#   export AWS_REGION=ap-northeast-2
#   export KEY_NAME=my-keypair
#   # 선택: SSH 허용 대역 (미설정 시 이 머신 공인 IP/32)
#   # export SSH_CIDR=203.0.113.10/32
#   # export VPC_ID_OVERRIDE=vpc-xxxxxxxx   # 기본 VPC 없을 때
#   # export BACKEND_GHCR_IMAGE=ghcr.io/yourorg/medical-service-backend:latest
#   # (EC2에 /opt/medical-backend.env 있으면 docker run --env-file 로 전달)
#   bash scripts/aws-cli-ec2-alb-backend.sh
#
# 실제 Spring 백엔드로 교체한 뒤 ALB 헬스는 /health 로 두는 것을 권장합니다.
# (이 저장소 백엔드는 /health 가 200을 반환합니다.)

set -euo pipefail

: "${AWS_REGION:?Set AWS_REGION (e.g. ap-northeast-2)}"
: "${KEY_NAME:?Set KEY_NAME to an existing EC2 key pair name in $AWS_REGION}"

STACK_NAME="${STACK_NAME:-medical-backend-alb}"
INSTANCE_TYPE="${INSTANCE_TYPE:-t3.micro}"
BACKEND_PORT="${BACKEND_PORT:-3000}"
# Optional: GHCR image (e.g. ghcr.io/yourorg/medical-service-backend:latest). Set on EC2 /opt/medical-backend.env for Spring env.
BACKEND_GHCR_IMAGE="${BACKEND_GHCR_IMAGE:-}"
SSH_CIDR="${SSH_CIDR:-}"
RUN_SUFFIX="${RUN_SUFFIX:-$(date +%s)}"

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
_INFRA_ROOT="$(cd "$_SCRIPT_DIR/.." && pwd)"

# WSL 등: PATH에 aws 없으면 Windows용 AWS CLI v2 실행 파일 사용
_aws_exe=""
if command -v aws &>/dev/null; then
  _aws_exe="$(command -v aws)"
elif [[ -f "/mnt/c/Program Files/Amazon/AWSCLIV2/aws.exe" ]]; then
  _aws_exe="/mnt/c/Program Files/Amazon/AWSCLIV2/aws.exe"
elif [[ -f "/mnt/c/Program Files (x86)/Amazon/AWSCLIV2/aws.exe" ]]; then
  _aws_exe="/mnt/c/Program Files (x86)/Amazon/AWSCLIV2/aws.exe"
fi
if [[ -z "${_aws_exe:-}" ]]; then
  echo "error: aws CLI not found. Install AWS CLI v2 in WSL, or install for Windows (default: C:\\Program Files\\Amazon\\AWSCLIV2\\)." >&2
  exit 1
fi
aws() { "${_aws_exe}" "$@"; }
export -f aws 2>/dev/null || true

if [[ -z "$SSH_CIDR" ]]; then
  MYIP="$(curl -fsS --max-time 5 https://checkip.amazonaws.com | tr -d '[:space:]')"
  SSH_CIDR="${MYIP}/32"
  echo "Using SSH_CIDR=$SSH_CIDR (override with export SSH_CIDR=a.b.c.d/32)"
fi

echo "==> Resolve VPC (default, or VPC_ID_OVERRIDE, or first VPC with 2+ AZ subnets)"

aws_text_trim() {
  # Windows aws.exe + WSL: CRLF로 리소스 ID가 깨지는 것 방지 (\r \n 만 제거)
  local s="${1-}"
  s="$(printf '%s' "$s" | tr -d '\r\n')"
  [[ "$s" == "None" ]] && s=""
  printf '%s' "$s"
}

VPC_ID="$(aws ec2 describe-vpcs \
  --region "$AWS_REGION" \
  --filters Name=isDefault,Values=true \
  --query 'Vpcs[0].VpcId' --output text)"
VPC_ID="$(aws_text_trim "$VPC_ID")"

if [[ -z "$VPC_ID" && -n "${VPC_ID_OVERRIDE:-}" ]]; then
  VPC_ID="$(aws_text_trim "$VPC_ID_OVERRIDE")"
fi

if [[ -z "$VPC_ID" ]]; then
  echo "    (no default VPC — scanning VPCs)"
  while IFS= read -r candidate; do
    candidate="$(aws_text_trim "$candidate")"
    [[ -z "$candidate" ]] && continue
    mapfile -t _azs < <(aws ec2 describe-subnets \
      --region "$AWS_REGION" \
      --filters "Name=vpc-id,Values=$candidate" \
      --query 'Subnets[].AvailabilityZone' --output text | tr '\t' '\n' | sort -u)
    _n="${#_azs[@]}"
    if [[ "$_n" -ge 2 ]]; then
      VPC_ID="$candidate"
      echo "    using VPC $VPC_ID ($_n AZs)"
      break
    fi
  done < <(aws ec2 describe-vpcs --region "$AWS_REGION" --query 'Vpcs[].VpcId' --output text | tr '\t' '\n')
fi

if [[ -z "$VPC_ID" ]]; then
  echo "error: no usable VPC in $AWS_REGION." >&2
  echo "  Create a VPC with subnets in at least 2 AZs, or:" >&2
  echo "  export VPC_ID_OVERRIDE=vpc-xxxxxxxx" >&2
  exit 1
fi
echo "VPC_ID=$VPC_ID"

echo "==> Pick two subnets (different AZ)"
mapfile -t SUBNET_LINES < <(aws ec2 describe-subnets \
  --region "$AWS_REGION" \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'Subnets[*].[SubnetId,AvailabilityZone]' --output text | awk '!a[$2]++{print $1"\t"$2}')
if [[ "${#SUBNET_LINES[@]}" -lt 2 ]]; then
  echo "Need at least 2 subnets in different AZs in the default VPC."
  exit 1
fi
SUBNET_A="$(aws_text_trim "$(echo "${SUBNET_LINES[0]}" | awk '{print $1}')")"
SUBNET_B="$(aws_text_trim "$(echo "${SUBNET_LINES[1]}" | awk '{print $1}')")"
echo "SUBNET_A=$SUBNET_A SUBNET_B=$SUBNET_B"

echo "==> Security group for ALB"
ALB_SG_ID="$(aws ec2 create-security-group \
  --region "$AWS_REGION" \
  --group-name "${STACK_NAME}-alb-${RUN_SUFFIX}" \
  --description "ALB HTTP for ${STACK_NAME}" \
  --vpc-id "$VPC_ID" \
  --query 'GroupId' --output text)"
ALB_SG_ID="$(aws_text_trim "$ALB_SG_ID")"
aws ec2 authorize-security-group-ingress \
  --region "$AWS_REGION" \
  --group-id "$ALB_SG_ID" \
  --protocol tcp \
  --port 80 \
  --cidr 0.0.0.0/0 >/dev/null
echo "ALB_SG_ID=$ALB_SG_ID"

echo "==> Security group for EC2"
EC2_SG_ID="$(aws ec2 create-security-group \
  --region "$AWS_REGION" \
  --group-name "${STACK_NAME}-ec2-${RUN_SUFFIX}" \
  --description "Backend EC2 for ${STACK_NAME}" \
  --vpc-id "$VPC_ID" \
  --query 'GroupId' --output text)"
EC2_SG_ID="$(aws_text_trim "$EC2_SG_ID")"
aws ec2 authorize-security-group-ingress \
  --region "$AWS_REGION" \
  --group-id "$EC2_SG_ID" \
  --protocol tcp \
  --port "$BACKEND_PORT" \
  --source-group "$ALB_SG_ID" >/dev/null
aws ec2 authorize-security-group-ingress \
  --region "$AWS_REGION" \
  --group-id "$EC2_SG_ID" \
  --protocol tcp \
  --port 22 \
  --cidr "$SSH_CIDR" >/dev/null
echo "EC2_SG_ID=$EC2_SG_ID"

echo "==> Amazon Linux 2023 AMI (x86_64)"
AMI_ID="$(aws ssm get-parameters \
  --region "$AWS_REGION" \
  --names /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-x86_64 \
  --query 'Parameters[0].Value' --output text 2>/dev/null || true)"
AMI_ID="$(aws_text_trim "$AMI_ID")"
if [[ -z "$AMI_ID" ]]; then
  AMI_ID="$(aws ssm get-parameters \
    --region "$AWS_REGION" \
    --names /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-6.1-x86_64 \
    --query 'Parameters[0].Value' --output text 2>/dev/null || true)"
  AMI_ID="$(aws_text_trim "$AMI_ID")"
fi
if [[ -z "$AMI_ID" ]]; then
  echo "    (SSM empty — falling back to ec2 describe-images)"
  AMI_ID="$(aws ec2 describe-images \
    --region "$AWS_REGION" \
    --owners amazon \
    --filters "Name=name,Values=al2023-ami-*-x86_64" "Name=architecture,Values=x86_64" "Name=state,Values=available" \
    --query 'sort_by(Images, &CreationDate)[-1].ImageId' --output text)"
  AMI_ID="$(aws_text_trim "$AMI_ID")"
fi
if [[ -z "$AMI_ID" || "$AMI_ID" != ami-* ]]; then
  echo "error: could not resolve Amazon Linux 2023 x86_64 AMI (check SSM/EC2 IAM permissions)." >&2
  exit 1
fi
echo "AMI_ID=$AMI_ID"

USER_DATA_FILE="$(mktemp)"
WIN_TMP="${_INFRA_ROOT}/.aws-userdata-${RUN_SUFFIX}.sh"
trap 'rm -f "$USER_DATA_FILE" "$WIN_TMP"' EXIT
# Windows aws.exe: user-data는 ASCII-only + UTF-8 무BOM.
TG_HEALTH_PATH="/"
if [[ -n "${BACKEND_GHCR_IMAGE:-}" ]]; then
  TG_HEALTH_PATH="/health"
  cat >"$USER_DATA_FILE" <<EOF
#!/bin/bash
set -euxo pipefail
dnf install -y docker
systemctl enable --now docker
IMG='${BACKEND_GHCR_IMAGE}'
docker pull "\$IMG" || true
docker stop medicare-backend 2>/dev/null || true
docker rm medicare-backend 2>/dev/null || true
if [[ -f /opt/medical-backend.env ]]; then
  docker run -d --name medicare-backend --restart always -p ${BACKEND_PORT}:3000 --env-file /opt/medical-backend.env "\$IMG"
else
  docker run -d --name medicare-backend --restart always -p ${BACKEND_PORT}:3000 "\$IMG"
fi
EOF
else
  cat >"$USER_DATA_FILE" <<EOF
#!/bin/bash
set -euxo pipefail
dnf install -y python3
cd /tmp
nohup python3 -m http.server ${BACKEND_PORT} --bind 0.0.0.0 >/var/log/placeholder-http.log 2>&1 &
EOF
fi
cp "$USER_DATA_FILE" "$WIN_TMP"

# Windows aws.exe 는 WSL 전용 /tmp 경로의 file:// 를 읽지 못함 → 리포지터리(보통 /mnt/c/...)에 복사 후 Windows 경로로 전달
USER_DATA_URL=""
if [[ "$_aws_exe" == *[Aa]ws.exe ]]; then
  if command -v wslpath &>/dev/null; then
    _udw="$(wslpath -w "$WIN_TMP" 2>/dev/null)" || _udw=""
    if [[ -n "${_udw:-}" ]]; then
      USER_DATA_URL="file://$(printf '%s' "$_udw" | sed 's#\\#/#g')"
    fi
  fi
  if [[ -z "${USER_DATA_URL:-}" ]]; then
    echo "error: user-data path for Windows aws.exe failed (wslpath). Use repo under /mnt/c/... or install AWS CLI inside WSL." >&2
    exit 1
  fi
else
  USER_DATA_URL="file://${WIN_TMP}"
fi

echo "==> Launch EC2"
INSTANCE_ID="$(aws ec2 run-instances \
  --region "$AWS_REGION" \
  --image-id "$AMI_ID" \
  --instance-type "$INSTANCE_TYPE" \
  --key-name "$KEY_NAME" \
  --subnet-id "$SUBNET_A" \
  --security-group-ids "$EC2_SG_ID" \
  --associate-public-ip-address \
  --user-data "$USER_DATA_URL" \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${STACK_NAME}-backend},{Key=Project,Value=${STACK_NAME}}]" \
  --query 'Instances[0].InstanceId' --output text)"
INSTANCE_ID="$(aws_text_trim "$INSTANCE_ID")"
echo "INSTANCE_ID=$INSTANCE_ID"

aws ec2 wait instance-running --region "$AWS_REGION" --instance-ids "$INSTANCE_ID"
echo "EC2 is running."

TG_NAME="$(echo "${STACK_NAME}-tg-${RUN_SUFFIX}" | tr '[:upper:]' '[:lower:]' | tr '_' '-' | cut -c1-32)"
echo "==> Target group (HTTP -> port ${BACKEND_PORT}, health ${TG_HEALTH_PATH})"
TG_ARN="$(aws elbv2 create-target-group \
  --region "$AWS_REGION" \
  --name "$TG_NAME" \
  --protocol HTTP \
  --port "$BACKEND_PORT" \
  --vpc-id "$VPC_ID" \
  --target-type instance \
  --health-check-path "$TG_HEALTH_PATH" \
  --health-check-interval-seconds 15 \
  --healthy-threshold-count 2 \
  --unhealthy-threshold-count 3 \
  --query 'TargetGroups[0].TargetGroupArn' --output text)"
TG_ARN="$(aws_text_trim "$TG_ARN")"
echo "TG_ARN=$TG_ARN"

echo "==> Register EC2 to target group"
aws elbv2 register-targets \
  --region "$AWS_REGION" \
  --target-group-arn "$TG_ARN" \
  --targets "Id=$INSTANCE_ID"

echo "==> Application Load Balancer"
ALB_NAME="$(echo "${STACK_NAME}-alb-${RUN_SUFFIX}" | tr '[:upper:]' '[:lower:]' | tr '_' '-' | cut -c1-32)"
ALB_ARN="$(aws elbv2 create-load-balancer \
  --region "$AWS_REGION" \
  --name "$ALB_NAME" \
  --subnets "$SUBNET_A" "$SUBNET_B" \
  --security-groups "$ALB_SG_ID" \
  --scheme internet-facing \
  --type application \
  --ip-address-type ipv4 \
  --query 'LoadBalancers[0].LoadBalancerArn' --output text)"
ALB_ARN="$(aws_text_trim "$ALB_ARN")"
echo "ALB_ARN=$ALB_ARN"

echo "==> Wait until load balancer is active"
aws elbv2 wait load-balancer-available --region "$AWS_REGION" --load-balancer-arns "$ALB_ARN"

ALB_DNS="$(aws elbv2 describe-load-balancers \
  --region "$AWS_REGION" \
  --load-balancer-arns "$ALB_ARN" \
  --query 'LoadBalancers[0].DNSName' --output text)"
ALB_DNS="$(aws_text_trim "$ALB_DNS")"
echo "ALB_DNS=$ALB_DNS"

echo "==> Listener HTTP:80 -> target group"
LISTENER_ARN="$(aws elbv2 create-listener \
  --region "$AWS_REGION" \
  --load-balancer-arn "$ALB_ARN" \
  --protocol HTTP \
  --port 80 \
  --default-actions "Type=forward,TargetGroupArn=$TG_ARN" \
  --query 'Listeners[0].ListenerArn' --output text)"
LISTENER_ARN="$(aws_text_trim "$LISTENER_ARN")"
echo "LISTENER_ARN=$LISTENER_ARN"

echo ""
echo "========== 완료 =========="
echo "GitHub 프론트 저장소 Actions Secret NEXT_PUBLIC_API_URL 예:"
echo "  http://${ALB_DNS}"
echo ""
echo "Spring Docker 사용 시: EC2에 /opt/medical-backend.env 생성 후 재부팅하거나,"
echo "  스크립트 실행 전 export BACKEND_GHCR_IMAGE=ghcr.io/owner/medical-service-backend:latest"
echo "  ALB 타깃 헬스는 /health 로 바꾸세요:"
echo "  aws elbv2 modify-target-group --region $AWS_REGION --target-group-arn $TG_ARN --health-check-path /health"
echo ""
echo "삭제 시(참고): 대상 그룹에서 타깃 제거 → 리스너 삭제 → ALB 삭제 → TG 삭제 → EC2 종료 → 보안 그룹 삭제"
echo "리소스 ID:"
echo "  INSTANCE_ID=$INSTANCE_ID"
echo "  ALB_ARN=$ALB_ARN"
echo "  TG_ARN=$TG_ARN"
echo "  ALB_SG_ID=$ALB_SG_ID EC2_SG_ID=$EC2_SG_ID"
