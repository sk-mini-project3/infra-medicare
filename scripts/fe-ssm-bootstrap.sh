#!/bin/bash
set -euxo pipefail
dnf install -y docker aws-cli
systemctl enable --now docker
TOKEN_IMDS=$(curl -fsS -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
REGION=$(curl -fsS -H "X-aws-ec2-metadata-token: ${TOKEN_IMDS}" http://169.254.169.254/latest/meta-data/placement/region)
SECRET_JSON="$(aws secretsmanager get-secret-value --secret-id "${GHCR_SECRET_ID:-medicare/ghcr-read}" --region "$REGION" --query SecretString --output text)"
export SECRET_JSON
python3 -c "import json,subprocess,os;d=json.loads(os.environ['SECRET_JSON']); subprocess.run(['docker','login','ghcr.io','-u',d['username'],'--password-stdin'], input=d['token'].encode(), check=True)"
IMG="${GHCR_IMAGE:-ghcr.io/sk-mini-project3/frontend-medicare:latest}"
docker pull "$IMG"
docker rm -f medicare-frontend 2>/dev/null || true
docker run -d --name medicare-frontend --restart always -p 80:80 "$IMG"
