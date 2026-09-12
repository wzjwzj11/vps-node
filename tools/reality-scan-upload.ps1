param(
    [Parameter(Mandatory=$true)]
    [string]$VpsIp,

    [Parameter(Mandatory=$true)]
    [string]$SshTarget,

    [string]$SshKey = "",
    [string]$WorkDir = "D:\vps-node-scan",
    [int]$Thread = 100,
    [int]$Timeout = 5,
    [switch]$RunRemoteCheck
)

$ErrorActionPreference = "Stop"
$Version = "v0.2.3"
$ApiUrl = "https://github.com/XTLS/RealiTLScanner/releases/download/$Version/RealiTLScanner-windows-64.exe"
$Scanner = Join-Path $WorkDir "RealiTLScanner-windows-64.exe"
$Csv = Join-Path $WorkDir "reality-$($VpsIp.Replace(':','_'))-$(Get-Date -Format yyyyMMdd-HHmmss).csv"
$RemoteDir = "/root/reality-scan"

New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null

if (-not (Test-Path -LiteralPath $Scanner)) {
    Write-Host "下载 RealiTLScanner $Version ..." -ForegroundColor Cyan
    Invoke-WebRequest -Uri $ApiUrl -OutFile $Scanner -UseBasicParsing
}

Write-Host "扫描 VPS: $VpsIp ..." -ForegroundColor Cyan
& $Scanner -addr $VpsIp -port 443 -thread $Thread -timeout $Timeout -out $Csv
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $Csv)) {
    throw "RealiTLScanner 扫描失败或没有生成 CSV: $Csv"
}

$sshArgs = @()
if ($SshKey) { $sshArgs += @('-i', $SshKey) }

Write-Host "创建 VPS 目录 $RemoteDir ..." -ForegroundColor Cyan
& ssh @sshArgs $SshTarget "mkdir -p $RemoteDir"
if ($LASTEXITCODE -ne 0) { throw "SSH 无法连接: $SshTarget" }

Write-Host "上传 CSV: $Csv ..." -ForegroundColor Cyan
& scp @sshArgs $Csv "${SshTarget}:$RemoteDir/"
if ($LASTEXITCODE -ne 0) { throw "CSV 上传失败" }

Write-Host "已上传。VPS 上运行菜单 6 进行 RealityChecker 检测和域名选择。" -ForegroundColor Green
if ($RunRemoteCheck) {
    Write-Host "启动 VPS 批量检测..." -ForegroundColor Cyan
    & ssh @sshArgs $SshTarget "ACTION=csv-scan bash /usr/local/bin/vps-node.sh"
    if ($LASTEXITCODE -ne 0) { throw "VPS 批量检测或域名修改失败" }
}

Write-Host "CSV: $Csv" -ForegroundColor Green
