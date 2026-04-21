[CmdletBinding()]
param(
  [string]$AwsRegion = "us-east-1",
  [string]$ProjectName = "crisis-pulse"
)

$ErrorActionPreference = "Stop"

function Require-Command {
  param([string]$Name)

  if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
    throw "Required command '$Name' is not installed or not on PATH."
  }
}

function Deploy-Lambda {
  param(
    [string]$FunctionName,
    [string]$SourceDir
  )

  $tempRoot = Join-Path $env:TEMP "crisis-pulse-$FunctionName"
  $zipFile = Join-Path $env:TEMP "$FunctionName.zip"

  if (Test-Path $tempRoot) {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force
  }
  New-Item -ItemType Directory -Path $tempRoot | Out-Null

  if (Test-Path $zipFile) {
    Remove-Item -LiteralPath $zipFile -Force
  }

  if (Test-Path (Join-Path $SourceDir "requirements.txt")) {
    py -m pip install -r (Join-Path $SourceDir "requirements.txt") -t $tempRoot | Out-Null
  }

  Copy-Item -LiteralPath (Join-Path $SourceDir "handler.py") -Destination (Join-Path $tempRoot "handler.py") -Force
  Compress-Archive -Path (Join-Path $tempRoot "*") -DestinationPath $zipFile -Force

  aws lambda update-function-code `
    --function-name "$ProjectName-$FunctionName" `
    --zip-file "fileb://$zipFile" `
    --region $AwsRegion `
    --output text `
    --query FunctionName
}

Require-Command -Name "aws"
Require-Command -Name "py"

$repoRoot = Split-Path -Parent $PSScriptRoot

Deploy-Lambda -FunctionName "classifier" -SourceDir (Join-Path $repoRoot "lambdas\classifier")
Deploy-Lambda -FunctionName "api-handler" -SourceDir (Join-Path $repoRoot "lambdas\api_handler")
Deploy-Lambda -FunctionName "alert-engine" -SourceDir (Join-Path $repoRoot "lambdas\alert_engine")

Write-Host "Lambda deployment complete." -ForegroundColor Green
