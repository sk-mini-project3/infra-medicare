<#.
  SSH 없이 Systems Manager(HTTPS/443)로 ai-medicare 배포.
  선행 조건:
    - 인스턴스 IAM 프로파일에 AmazonSSMManagedInstanceCore
    - SSM PingStatus=Online
    - GHCR private면 medicare/ghcr-read 시크릿(username, token JSON)
#>
param(
  [Parameter(Mandatory = $true)][string]$InstanceId,
  [string]$Region = 'ap-northeast-2',
  [string]$GhcrImage = 'ghcr.io/sk-mini-project3/ai-medicare:latest',
  [string]$EnvFile = ''
)

$ErrorActionPreference = 'Stop'
$env:AWS_REGION = $Region

if (-not $EnvFile) {
  $EnvFile = Join-Path (Split-Path -Parent $PSCommandPath) '..\medical-ai.env'
}
$EnvFile = [System.IO.Path]::GetFullPath($EnvFile)
if (-not (Test-Path -LiteralPath $EnvFile)) {
  throw "Env file not found: $EnvFile"
}

$envPlain = [System.IO.File]::ReadAllText($EnvFile, [System.Text.UTF8Encoding]::new($false))
$envB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($envPlain))
$imgB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($GhcrImage))

$ghcrLoginSh = @'
if [ -n "${SECRET_JSON:-}" ] && [ "$SECRET_JSON" != "None" ]; then
  export SECRET_JSON
  python3 -c "import json,subprocess,os;d=json.loads(os.environ['SECRET_JSON']); subprocess.run(['docker','login','ghcr.io','-u',d['username'],'--password-stdin'], input=d['token'].encode(), check=True)"
fi
'@
$ghcrLoginSh = $ghcrLoginSh -replace "`r`n","`n"
$ghcrLoginB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($ghcrLoginSh))

$bootstrap = @(
  'set -euxo pipefail',
  'sudo mkdir -p /opt',
  "printf '%s' '$envB64' | base64 -d | sudo tee /opt/medical-ai.env >/dev/null",
  'sudo chmod 600 /opt/medical-ai.env',
  "printf '%s' '$imgB64' | base64 -d | sudo tee /opt/medical-ai-image >/dev/null",
  'sudo chmod 600 /opt/medical-ai-image',
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
  "IMG=`$(sudo tr -d '\r\n' < /opt/medical-ai-image)",
  'sudo docker pull "$IMG"',
  'sudo docker stop medicare-ai 2>/dev/null || true',
  'sudo docker rm medicare-ai 2>/dev/null || true',
  'sudo docker run -d --name medicare-ai --restart always -p 8001:8001 --env-file /opt/medical-ai.env "$IMG"',
  'sudo docker ps'
) -join "`n"

$b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($bootstrap))
$remote = "printf '%s' '$b64' | base64 -d | sudo bash"

$input = @{
  InstanceIds  = @($InstanceId)
  DocumentName = 'AWS-RunShellScript'
  Comment      = 'deploy ai medicare via ssm'
  Parameters   = @{ commands = @($remote) }
}
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("ssm-ai-{0}.json" -f [Guid]::NewGuid().ToString('N'))
[System.IO.File]::WriteAllText($tmp, ($input | ConvertTo-Json -Depth 6), [System.Text.UTF8Encoding]::new($false))
$uri = 'file://' + ($tmp -replace '\\', '/')

$send = aws ssm send-command --cli-input-json $uri --output json | ConvertFrom-Json
Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue

$cid = $send.Command.CommandId
Write-Host "CommandId=$cid"
aws ssm wait command-executed --command-id $cid --instance-id $InstanceId
$status = aws ssm get-command-invocation --command-id $cid --instance-id $InstanceId --output json | ConvertFrom-Json
Write-Host "Status=$($status.Status)"
Write-Host $status.StandardOutputContent
if ($status.StandardErrorContent) { Write-Host $status.StandardErrorContent }
if ($status.Status -ne 'Success') { exit 1 }
