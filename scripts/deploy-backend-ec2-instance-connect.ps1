#Requires -Version 5.1
<#
  EC2에 Docker로 백엔드(GHCR) 배포.
  반드시 EC2 보안 그룹에서 SSH(22)가 허용된 공인 IP인 PC에서 실행하세요 (예: 집 인터넷).

  Test-NetConnection ... -Port 22 이 실패(타임아웃)하면: 일부 ISP/공유기가 나가는 SSH(22)를 막는 경우가 있습니다.
  그때는 SSH 없이 Systems Manager로 같은 작업을 하는 deploy-backend-ssm.ps1 을 사용하세요.

  예:
    .\deploy-backend-ec2-instance-connect.ps1 `
      -Region ap-northeast-2 `
      -InstanceId i-0bd6637c713a64270 `
      -GhcrImage "ghcr.io/sk-mini-project3/backend-medicare:latest" `
      -EnvFile "C:\path\medical-backend.env"

  medical-backend.env: medical-service-infra/medical-backend.env.example 을 복사해 값 채운 뒤 사용 (Git 커밋 금지).
    ssh ... "echo PAT | docker login ghcr.io -u USER --password-stdin"
#>
param(
  [string] $Region = "ap-northeast-2",
  [Parameter(Mandatory = $true)][string] $InstanceId,
  [Parameter(Mandatory = $true)][string] $GhcrImage,
  [Parameter(Mandatory = $true)][string] $EnvFile,
  [string] $InstanceUser = "ec2-user"
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $EnvFile)) {
  Write-Error "Env file not found: $EnvFile"
}

$az = (aws ec2 describe-instances --region $Region --instance-ids $InstanceId `
    --query "Reservations[0].Instances[0].Placement.AvailabilityZone" --output text).Trim()
$publicIp = (aws ec2 describe-instances --region $Region --instance-ids $InstanceId `
    --query "Reservations[0].Instances[0].PublicIpAddress" --output text).Trim()
if ([string]::IsNullOrWhiteSpace($publicIp) -or $publicIp -eq "None") {
  Write-Error "Instance has no public IP (or not running)."
}
Write-Host "AZ=$az  PublicIp=$publicIp"

$keyDir = Join-Path $env:TEMP ("ec2ic-" + [guid]::NewGuid().ToString("N").Substring(0, 10))
New-Item -ItemType Directory -Path $keyDir -Force | Out-Null
$key = Join-Path $keyDir "key"
$keyPub = "$key.pub"
ssh-keygen -t ed25519 -f $key -N '""' -q

# Windows aws.exe: file:///C:/... 는 Errno 22 — file://C:/... 형식만 로드됨
$pubUri = "file://" + ($keyPub -replace "\\", "/")
$send = aws ec2-instance-connect send-ssh-public-key `
  --region $Region `
  --instance-id $InstanceId `
  --availability-zone $az `
  --instance-os-user $InstanceUser `
  --ssh-public-key $pubUri | ConvertFrom-Json
if (-not $send.Success) {
  Write-Error "send-ssh-public-key failed"
}

Write-Host "Uploading env ..."
scp -i $key -o StrictHostKeyChecking=no $EnvFile "${InstanceUser}@${publicIp}:/tmp/medical-backend.env"

$imgB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($GhcrImage))

$remoteLines = @(
  'set -euxo pipefail',
  'sudo mkdir -p /opt',
  'sudo mv /tmp/medical-backend.env /opt/medical-backend.env',
  'sudo chmod 600 /opt/medical-backend.env',
  "echo $imgB64 | base64 -d | sudo tee /opt/medical-backend-image >/dev/null",
  'sudo chmod 600 /opt/medical-backend-image',
  "sudo pkill -f 'python3 -m http.server' || true",
  'if ! command -v docker >/dev/null 2>&1; then sudo dnf install -y docker || sudo yum install -y docker; fi',
  'sudo systemctl enable --now docker',
  'IMG=$(sudo tr -d ''\r\n'' < /opt/medical-backend-image)',
  'sudo docker pull "$IMG" || true',
  'sudo docker stop medicare-backend 2>/dev/null || true',
  'sudo docker rm medicare-backend 2>/dev/null || true',
  'sudo docker run -d --name medicare-backend --restart always -p 3000:3000 --env-file /opt/medical-backend.env "$IMG"',
  'sudo docker ps'
)
$remoteBash = ($remoteLines -join "`n")
$b64script = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($remoteBash))

Write-Host "Running remote bootstrap (Instance Connect key expires quickly) ..."
ssh -i $key -o StrictHostKeyChecking=no "${InstanceUser}@${publicIp}" "echo $b64script | base64 -d | sudo bash"

Remove-Item -Recurse -Force $keyDir -ErrorAction SilentlyContinue
Write-Host "Probe: curl -sS http://${publicIp}:3000/health"
