<#.
  GHCR 비공개 이미지를 이미 띄운 프론트 EC2에 올립니다.
  선행 조건:
    1) Secrets Manager에 시크릿 생성 (예시):
       aws secretsmanager create-secret --name medicare/ghcr-read --region ap-northeast-2 `
         --secret-string '{\"username\":\"YOUR_GITHUB_USER\",\"token\":\"ghp_xxx\"}'
       (이미 있으면 put-secret-value로 갱신)
    2) EC2에 medicare-fe-ec2-profile(또는 동일 정책)이 붙어 있고 SSM PingStatus=Online
  사용:
    .\deploy-frontend-ssm.ps1 -InstanceId i-0f4c12f3e711e314e
#>
param(
  [Parameter(Mandatory = $true)][string]$InstanceId,
  [string]$Region = 'ap-northeast-2',
  [string]$BootstrapPath = ''
)
if (-not $BootstrapPath) {
  $dir = Split-Path -Parent $PSCommandPath
  $BootstrapPath = Join-Path $dir 'fe-ssm-bootstrap.sh'
}

$ErrorActionPreference = 'Stop'
$env:AWS_REGION = $Region
if (-not (Test-Path $BootstrapPath)) { throw "Missing $BootstrapPath" }

$script = [System.IO.File]::ReadAllText($BootstrapPath, [System.Text.UTF8Encoding]::new($false))
$b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($script))
$remote = "printf '%s' '$b64' | base64 -d | bash"

if ($remote -match '"') { throw 'Remote bootstrap command unexpectedly contains double quotes' }
$sendInput = @{
  InstanceIds  = @($InstanceId)
  DocumentName = 'AWS-RunShellScript'
  Comment      = 'medicare frontend: GHCR pull + docker run'
  Parameters   = @{ commands = @($remote) }
}
$sendJsonPath = Join-Path ([System.IO.Path]::GetTempPath()) ("ssm-send-{0}.json" -f [Guid]::NewGuid().ToString('N'))
$jsonText = $sendInput | ConvertTo-Json -Depth 6
[System.IO.File]::WriteAllText($sendJsonPath, $jsonText, [System.Text.UTF8Encoding]::new($false))
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
