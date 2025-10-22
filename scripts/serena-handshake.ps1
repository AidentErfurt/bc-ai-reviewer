param()

$ErrorActionPreference = 'Stop'

. "$PSScriptRoot/serena-common.ps1"

$TimeoutSec = [int](${Env:SERENA_TIMEOUT_SEC} ?? 60)

# Prefer input SERENA_URL if provided; else env from start step
$Url = if ($env:SERENA_URL_INPUT) { $env:SERENA_URL_INPUT } elseif ($env:SERENA_URL) { $env:SERENA_URL } else { "" }
if (-not $Url) { throw "SERENA_URL not set (neither input nor env)." }

# Probe session header (unless already provided by a previous step)
$Sid = $Env:SERENA_SESSION_ID
$Hdr = $Env:SERENA_SESSION_HDR
if (-not $Sid -or -not $Hdr) {
  $urlsToTry = @($Url.TrimEnd('/'), "$($Url.TrimEnd('/'))/", ($Url -replace '/mcp/?$','/'))
  $session = $null
  foreach($u in $urlsToTry){ $session = Probe-SerenaSessionHeader -Url $u; if($session){ $Url = $u; break } }
  if (-not $session) { throw "Serena handshake failed: no Mcp session header found." }
  $Sid = $session.Id
  $Hdr = $session.Name
  "SERENA_URL=$Url"            | Out-File -FilePath $env:GITHUB_ENV -Append -Encoding ascii
  "SERENA_SESSION_ID=$Sid"     | Out-File -FilePath $env:GITHUB_ENV -Append -Encoding ascii
  "SERENA_SESSION_HDR=$Hdr"    | Out-File -FilePath $env:GITHUB_ENV -Append -Encoding ascii
  Write-Host "Using session header name: $Hdr"
  Write-Host "Using session id value : $Sid"
}

# initialize (SSE)
$initBodyObj = @{
  jsonrpc = '2.0'
  id      = 'init-1'
  method  = 'initialize'
  params  = @{
    protocolVersion = '2024-10-07'
    capabilities    = @{}
    clientInfo      = @{ name='bc-ai-reviewer'; version='0.1.0' }
  }
}
$initResp = Invoke-SerenaRpc -Url $Url -SessionId $Sid -SessionHdrName $Hdr `
  -Id $initBodyObj.id -Method $initBodyObj.method -Params $initBodyObj.params -TimeoutSec $TimeoutSec
if (-not $initResp.result) { throw "initialize returned no result." }

# tools/list - omit params entirely for first page
# First page: ABSOLUTELY NO params property
$tl = Invoke-SerenaRpc -Url $Url -SessionId $Sid -SessionHdrName $Hdr `
  -Id ([guid]::NewGuid().ToString()) -Method 'tools/list' -Params $null -TimeoutSec $TimeoutSec

# Optional paging:
if ($tl.result -and $tl.result.nextCursor) {
  $cursor = [string]$tl.result.nextCursor  # ensure it’s string
  $tl2 = Invoke-SerenaRpc -Url $Url -SessionId $Sid -SessionHdrName $Hdr `
    -Id ([guid]::NewGuid().ToString()) -Method 'tools/list' -Params @{ cursor = $cursor } -TimeoutSec $TimeoutSec
  # merge pages if you want…
}

$toolNames = @()
if ($tl.result -and $tl.result.tools) {
  $toolNames = $tl.result.tools | ForEach-Object { $_.name }
}
if (-not $toolNames -or $toolNames.Count -eq 0) { throw "Serena returned no tools." }

# assert required tools exist
$required = @('get_symbols_overview','find_referencing_symbols')
foreach ($need in $required) {
  if ($toolNames -notcontains $need) {
    throw "Required Serena tool missing: $need (available: $($toolNames -join ', '))"
  }
}
Write-Host "Serena required tools present: $($required -join ', ')"

# activate every project with an app.json (if tool exists)
if ($toolNames -contains 'activate_project') {
  $apps = Get-ChildItem -Path $env:GITHUB_WORKSPACE -Filter 'app.json' -Recurse -File -ErrorAction SilentlyContinue
  if ($apps) {
    foreach ($app in $apps) {
      $projDir = Split-Path $app.FullName -Parent
      Write-Host "Activating Serena project: $projDir"
      try {
        Invoke-SerenaTool -Url $Url -SessionId $Sid -SessionHdrName $Hdr -Name 'activate_project' `
          -ToolArgs @{ project = $projDir } -TimeoutSec $TimeoutSec | Out-Null
      } catch {
        Write-Warning "activate_project failed for $($projDir): $($_.Exception.Message)"
      }
    }
  } else {
    Write-Host "No app.json found under $env:GITHUB_WORKSPACE"
  }
} else {
  Write-Host "activate_project tool not available; skipping project activation."
}

Write-Host "Serena handshake complete."
