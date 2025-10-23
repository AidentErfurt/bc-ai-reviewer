param()

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/serena-common.ps1"

$TimeoutSec = [int](${Env:SERENA_TIMEOUT_SEC} ?? 60)
$Url = if ($env:SERENA_URL_INPUT) { $env:SERENA_URL_INPUT } elseif ($env:SERENA_URL) { $env:SERENA_URL } else { "" }
if (-not $Url) { throw "SERENA_URL not set (neither input nor env)." }

# Probe an MCP session header (id + header name), set envs for later steps
$Sid = $Env:SERENA_SESSION_ID
$Hdr = $Env:SERENA_SESSION_HDR
if (-not $Sid -or -not $Hdr) {
  $urlsToTry = @($Url.TrimEnd('/'), "$($Url.TrimEnd('/'))/", ($Url -replace '/mcp/?$','/'))
  $session = $null
  foreach($u in $urlsToTry){ $session = Probe-SerenaSessionHeader -Url $u; if($session){ $Url = $u; break } }
  if (-not $session) { throw "Serena handshake failed: no MCP session header found." }
  $Sid = $session.Id
  $Hdr = $session.Name
  "SERENA_URL=$Url"         | Out-File -FilePath $env:GITHUB_ENV -Append -Encoding ascii
  "SERENA_SESSION_ID=$Sid"  | Out-File -FilePath $env:GITHUB_ENV -Append -Encoding ascii
  "SERENA_SESSION_HDR=$Hdr" | Out-File -FilePath $env:GITHUB_ENV -Append -Encoding ascii
}

Write-Host "Serena MCP: $Url"
Write-Host "Session hdr: $Hdr"
Write-SerenaDebug "Session id: $Sid"

# --- initialize ---
$initParams = @{
  protocolVersion = '2025-06-18'  # match FastMCP 1.12.x
  capabilities    = @{}
  clientInfo      = @{ name='bc-ai-reviewer'; version='0.1.0' }
}
$init = Invoke-SerenaRpc -Url $Url -SessionId $Sid -SessionHdrName $Hdr `
  -Id 'init-1' -Method 'initialize' -Params $initParams -TimeoutSec $TimeoutSec
if (-not $init.result) { throw "initialize returned no result." }

$negotiated = $init.result.protocolVersion
$serverName = $init.result.serverInfo.name
$serverVer  = $init.result.serverInfo.version
Write-Host "Initialized (protocol $negotiated) on $serverName $serverVer"

# Required for FastMCP: send notifications/initialized
Send-SerenaNotification -Url $Url -SessionId $Sid -SessionHdrName $Hdr `
  -Method 'notifications/initialized' -Params @{} -TimeoutSec $TimeoutSec

# --- tools/list with robust paging & schema quirks ---
function Get-SerenaTools {
  param(
    [Parameter(Mandatory)] [string]$Url,
    [Parameter(Mandatory)] [string]$Sid,
    [Parameter(Mandatory)] [string]$Hdr,
    [int]$TimeoutSec = 60
  )
  $all = New-Object System.Collections.Generic.List[object]
  $cursor = $null

  do {
    $params = $null
    if ($cursor) { $params = @{ cursor = $cursor } }

    $resp = Invoke-SerenaRpc -Url $Url -SessionId $Sid -SessionHdrName $Hdr `
      -Id ([guid]::NewGuid()).Guid -Method 'tools/list' -Params $params -TimeoutSec $TimeoutSec

    if (-not $resp.result -or -not $resp.result.tools) {
      throw "tools/list returned no tools."
    }

    $all.AddRange($resp.result.tools)

    # Handle both nextCursor and next_cursor (defensive)
    if ($resp.result.PSObject.Properties.Name -contains 'nextCursor') {
      $cursor = $resp.result.nextCursor
    } elseif ($resp.result.PSObject.Properties.Name -contains 'next_cursor') {
      $cursor = $resp.result.next_cursor
    } else {
      $cursor = $null
    }
  } while ($cursor)

  return ,$all.ToArray()
}

$tools = Get-SerenaTools -Url $Url -Sid $Sid -Hdr $Hdr -TimeoutSec $TimeoutSec
$toolNames = $tools | ForEach-Object { $_.name } | Sort-Object -Unique
if (-not $toolNames -or $toolNames.Count -eq 0) { throw "Serena returned no tools." }

# Assert required set
$required = @('get_symbols_overview','find_referencing_symbols')
$missing = @()
foreach ($need in $required) {
  if ($toolNames -notcontains $need) { $missing += $need }
}
if ($missing.Count) {
  throw "Required Serena tool(s) missing: $($missing -join ', ') (available: $($toolNames -join ', '))"
}

Write-Host "Tool count: $($toolNames.Count)"
Write-Host "Required tools present: $($required -join ', ')"

# Export structured tool list for later steps (machine-readable)
$toolsJson = $tools | ConvertTo-Json -Depth 8 -Compress
"SERENA_TOOLS_JSON=$toolsJson" | Out-File -FilePath $env:GITHUB_ENV -Append -Encoding ascii

# Optionally, print a compact human summary (first 10)
$show = ($toolNames | Select-Object -First 10) -join ', '
Write-Host "Tools: $show$(if ($toolNames.Count -gt 10) { ', …' })"

# Build compact Markdown list of first 40 tools (serena has 27 atm)
$bt = [char]96  # literal `
$toolsListMd = (
  $toolNames | Select-Object -First 40 |
    ForEach-Object { "- $bt$($_)$bt" }
) -join "`n"

# Nice step summary
if ($env:GITHUB_STEP_SUMMARY) {
  @"
### Serena MCP Handshake

- Server: **$serverName $serverVer**
- Protocol: **$negotiated**
- Tools available: **$($toolNames.Count)**
- Required: **$($required -join ', ')**

<details><summary>Serena tools</summary>

$toolsListMd

</details>
"@ | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append -Encoding utf8
}

Write-Host "Serena handshake complete."
