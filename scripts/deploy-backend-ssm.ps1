<#.
  SSH(22)가 막혀 있을 때 — HTTPS(SSM)만으로 백엔드 배포 (scp/ssh 불필요).

  선행 조건:
    - 인스턴스에 IAM 인스턴스 프로파일이 붙어 있고 AmazonSSMManagedInstanceCore 권한
    - SSM: aws ssm describe-instance-information 에 PingStatus=Online
    - GHCR 이미지가 비공개면 Secrets Manager 시크릿 medicare/ghcr-read (JSON: username, token) + EC2 역할에 GetSecretValue

  예:
    .\deploy-backend-ssm.ps1 `
      -Region ap-northeast-2 `
      -InstanceId i-0bd6637c713a64270 `
      -GhcrImage "ghcr.io/sk-mini-project3/backend-medicare:latest" `
      -EnvFile "C:\mini_project_3\medical-service-infra\medical-backend.env"
#>
param(
  [Parameter(Mandatory = $true)][string]$InstanceId,
  [Parameter(Mandatory = $true)][string]$GhcrImage,
  [Parameter(Mandatory = $true)][string]$EnvFile,
  [string]$Region = 'ap-northeast-2'
)

$ErrorActionPreference = 'Stop'
$env:AWS_REGION = $Region

if (-not (Test-Path -LiteralPath $EnvFile)) {
  throw "Env file not found: $EnvFile"
}

$envPlain = [System.IO.File]::ReadAllText($EnvFile, [System.Text.UTF8Encoding]::new($false))
$envB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($envPlain))
$imgB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($GhcrImage))

# Bash+Python 한 줄을 PS 문자열에 넣으면 [, ], () 때문에 파서 오류 → 원격에서 디코드할 작은 스크립트만 별도 base64
$ghcrLoginSh = @'
if [ -n "${SECRET_JSON:-}" ] && [ "$SECRET_JSON" != "None" ]; then
  export SECRET_JSON
  python3 -c "import json,subprocess,os;d=json.loads(os.environ['SECRET_JSON']); subprocess.run(['docker','login','ghcr.io','-u',d['username'],'--password-stdin'], input=d['token'].encode(), check=True)"
fi
'@
$ghcrLoginSh = $ghcrLoginSh -replace "`r`n","`n"
$ghcrLoginB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($ghcrLoginSh))

$bootstrapLines = @(
  'set -euxo pipefail',
  'sudo mkdir -p /opt',
  "printf '%s' '$envB64' | base64 -d | sudo tee /opt/medical-backend.env >/dev/null",
  'sudo chmod 600 /opt/medical-backend.env',
  "printf '%s' '$imgB64' | base64 -d | sudo tee /opt/medical-backend-image >/dev/null",
  'sudo chmod 600 /opt/medical-backend-image',
  "sudo pkill -f 'python3 -m http.server' || true",
  'if ! command -v docker >/dev/null 2>&1; then sudo dnf install -y docker || sudo yum install -y docker; fi',
  'if ! command -v aws >/dev/null 2>&1; then sudo dnf install -y aws-cli || sudo yum install -y aws-cli; fi',
  'sudo systemctl enable --now docker',
  'TOKEN_IMDS=$(curl -fsS -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")',
  'REGION=$(curl -fsS -H "X-aws-ec2-metadata-token: ${TOKEN_IMDS}" http://169.254.169.254/latest/meta-data/placement/region)',
  'set +e',
  'SECRET_JSON=$(aws secretsmanager get-secret-value --secret-id medicare/ghcr-read --region "$REGION" --query SecretString --output text 2>/dev/null)',
  'set -e',
  'export SECRET_JSON',
  'python3 - <<''PY''',
  'import json, os',
  's = os.environ.get("SECRET_JSON", "")',
  'if not s or s == "None":',
  '    raise SystemExit("Secrets Manager medicare/ghcr-read is empty")',
  'try:',
  '    d = json.loads(s)',
  'except Exception as e:',
  '    raise SystemExit(f"medicare/ghcr-read must be JSON: {e}")',
  'if not d.get("username") or not d.get("token"):',
  '    raise SystemExit("medicare/ghcr-read needs username and token fields")',
  'PY',
  "printf '%s' '$ghcrLoginB64' | base64 -d | bash",
  'IMG=$(sudo tr -d ''\r\n'' < /opt/medical-backend-image)',
  'sudo docker pull "$IMG"',
  'sudo docker stop medicare-backend 2>/dev/null || true',
  'sudo docker rm medicare-backend 2>/dev/null || true',
  'sudo docker run -d --name medicare-backend --restart always -p 3000:3000 --env-file /opt/medical-backend.env "$IMG"',
  'sudo docker ps'
)
$bootstrap = ($bootstrapLines -join "`n")
$scriptB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($bootstrap))
$remote = "printf '%s' '$scriptB64' | base64 -d | sudo bash"

if ($remote -match '"') { throw 'Remote command unexpectedly contains double quotes' }

$sendInput = @{
  InstanceIds  = @($InstanceId)
  DocumentName = 'AWS-RunShellScript'
  Comment      = 'medicare backend: env + docker run'
  Parameters   = @{ commands = @($remote) }
}
$sendJsonPath = Join-Path ([System.IO.Path]::GetTempPath()) ("ssm-backend-{0}.json" -f [Guid]::NewGuid().ToString('N'))
[System.IO.File]::WriteAllText($sendJsonPath, ($sendInput | ConvertTo-Json -Depth 6), [System.Text.UTF8Encoding]::new($false))
$sendUri = 'file://' + ($sendJsonPath -replace '\\', '/')
$send = aws ssm send-command --cli-input-json $sendUri --output json | ConvertFrom-Json
Remove-Item -LiteralPath $sendJsonPath -Force -ErrorAction SilentlyContinue

$cid = $send.Command.CommandId
Write-Host "CommandId=$cid"
aws ssm wait command-executed --command-id $cid --instance-id $InstanceId
$status = aws ssm get-command-invocation --command-id $cid --instance-id $InstanceId --output json | ConvertFrom-Json
Write-Host "Status=$($status.Status)"
Write-Host $status.StandardOutputContent
if ($status.StandardErrorContent) { Write-Host $status.StandardErrorContent }
if ($status.Status -ne 'Success') { exit 1 }

$pub = (aws ec2 describe-instances --region $Region --instance-ids $InstanceId --query 'Reservations[0].Instances[0].PublicIpAddress' --output text).Trim()
Write-Host "Probe: curl -sS http://${pub}:3000/health"
