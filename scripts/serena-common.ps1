param()

function New-SerenaHeaders {
  param([string]$Sid,[string]$Hdr)
  $h = @{}
  if ($Sid -and $Hdr) { $h[$Hdr] = $Sid }
  # Streamable HTTP requires client to accept both
  $h['Accept']       = 'application/json, text/event-stream'
  $h['Content-Type'] = 'application/json'
  return $h
}

function Parse-SerenaResponse {
  param([string]$Raw)
  $trim = $Raw.Trim()
  if ($trim.StartsWith('{')) { return ($trim | ConvertFrom-Json) }
  $last = ($Raw -split "`n" | Where-Object { $_.TrimStart().StartsWith('data: ') }) | Select-Object -Last 1
  if (-not $last) { throw "No SSE data line in response." }
  $json = $last.Substring($last.IndexOf('data: ') + 6).Trim()
  return ($json | ConvertFrom-Json)
}

function Invoke-SerenaRpc {
  param(
    [string]$Url,
    [string]$SessionId,
    [string]$SessionHdrName,
    [string]$Id,
    [string]$Method,
    $Params,
    [int]$TimeoutSec = 60
  )

  # Build payload WITHOUT params by default
  $payload = [ordered]@{
    jsonrpc = '2.0'
    id      = $Id
    method  = $Method
  }

  # Only include params when non-null AND not an empty hashtable
  $includeParams = ($Params -ne $null) -and -not ($Params -is [hashtable] -and $Params.Count -eq 0)
  if ($includeParams) { $payload['params'] = $Params }

  $body = ($payload | ConvertTo-Json -Depth 30)

  # DEBUG: print the body we're *actually* sending
  Write-Host ">>> Serena RPC request ($Method): $body"

  $headers = New-SerenaHeaders -Sid $SessionId -Hdr $SessionHdrName
  try {
    $resp = Invoke-WebRequest -Uri $Url -Method POST -Headers $headers -Body $body `
              -TimeoutSec $TimeoutSec -SkipHttpErrorCheck
  } catch {
    Write-Host "HTTP exception for $($Method): $($_.Exception.Message)"
    throw
  }

  $raw = [string]$resp.Content
  # DEBUG: raw response (trim big streams if needed)
  Write-Host "<<< Serena RPC raw response ($Method): $($raw.Substring(0,[Math]::Min($raw.Length, 2000)))"

  $obj = Parse-SerenaResponse -Raw $raw
  if ($obj.error) {
    # Show full error object if present
    $errJson = ($obj.error | ConvertTo-Json -Depth 30)
    Write-Host "!!! Serena RPC error ($Method): $errJson"
    throw "RPC $Method failed: $($obj.error.code) $($obj.error.message)"
  }
  return $obj
}

function Invoke-SerenaTool {
  param(
    [string]$Url,
    [string]$SessionId,
    [string]$SessionHdrName,
    [string]$Name,
    $ToolArgs = $null,
    [int]$TimeoutSec = 60
  )
  if ($ToolArgs -is [array]) {
    if ($ToolArgs.Count -eq 0) { $ToolArgs = $null }
    elseif ($ToolArgs.Count -eq 1 -and $ToolArgs[0] -is [hashtable]) { $ToolArgs = $ToolArgs[0] }
    else { throw "Invoke-SerenaTool: ToolArgs must be a single hashtable or empty; got array length $($ToolArgs.Count)." }
  } elseif ($ToolArgs -isnot [hashtable] -and $ToolArgs -ne $null) {
    throw "Invoke-SerenaTool: ToolArgs must be a hashtable or `$null; got $($ToolArgs.GetType().FullName)."
  }

  $p = @{ name = $Name }
  if ($ToolArgs -is [hashtable] -and $ToolArgs.Count -gt 0) { $p.arguments = $ToolArgs }

  Invoke-SerenaRpc -Url $Url -SessionId $SessionId -SessionHdrName $SessionHdrName `
    -Id ([guid]::NewGuid()) -Method 'tools/call' -Params $p -TimeoutSec $TimeoutSec
}

function Probe-SerenaSessionHeader {
  param([string]$Url)
  Write-Host "== Probing Serena at $Url =="
  $sessionId = $null; $headerName = $null

  function Dump-Headers([hashtable]$h){ if($h){ foreach($k in $h.Keys){ Write-Host "  $($k): $($h[$k])" } } }

  try {
    $h = Invoke-WebRequest -Uri $Url -Method HEAD -TimeoutSec 3 -SkipHttpErrorCheck
    Write-Host "-- HEAD headers --"; Dump-Headers $h.Headers
    foreach($cand in @('Mcp-Session-Id','Mcp-Session')){ if($h.Headers[$cand]){ $sessionId = "$($h.Headers[$cand])".Trim(); $headerName=$cand; break } }
    if ($sessionId){ return [pscustomobject]@{ Id=$sessionId; Name=$headerName } }
  } catch { Write-Host "HEAD failed: $($_.Exception.Message)" }

  try {
    $g = Invoke-WebRequest -Uri $Url -Method GET -Headers @{Accept='text/event-stream'} -TimeoutSec 4 -SkipHttpErrorCheck
    Write-Host "-- GET headers --"; Dump-Headers $g.Headers
    foreach($cand in @('Mcp-Session-Id','Mcp-Session')){ if($g.Headers[$cand]){ $sessionId = "$($g.Headers[$cand])".Trim(); $headerName=$cand; break } }
    if ($sessionId){ return [pscustomobject]@{ Id=$sessionId; Name=$headerName } }
  } catch { Write-Host "GET failed: $($_.Exception.Message)" }

  try {
    $raw = & /usr/bin/curl -sS -D - -o /dev/null -H 'Accept: text/event-stream' "$Url"
    $rawNoCR = $raw -replace "`r",""
    Write-Host "-- curl -D - raw headers --"; $rawNoCR -split "`n" | ForEach-Object { Write-Host "  $_" }
    $m = [regex]::Match($rawNoCR, '(?im)^\s*(Mcp-Session-Id|Mcp-Session)\s*:\s*(.+?)\s*$')
    if ($m.Success){ return [pscustomobject]@{ Id=$m.Groups[2].Value.Trim(); Name=$m.Groups[1].Value } }
  } catch { Write-Host "curl probe failed: $($_.Exception.Message)" }

  return $null
}

function Send-SerenaNotification {
  param(
    [Parameter(Mandatory)] [string]$Url,
    [Parameter(Mandatory)] [string]$SessionId,
    [Parameter(Mandatory)] [string]$SessionHdrName,
    [Parameter(Mandatory)] [string]$Method,
    $Params = $null,
    [int]$TimeoutSec = 60
  )
  $headers = New-SerenaHeaders -Sid $SessionId -Hdr $SessionHdrName
  $payload = @{ jsonrpc = '2.0'; method = $Method }
  if ($Params -ne $null) { $payload['params'] = $Params }
  $body = $payload | ConvertTo-Json -Depth 20 -Compress
  Invoke-WebRequest -Uri $Url -Method POST -Headers $headers -Body $body -TimeoutSec $TimeoutSec -SkipHttpErrorCheck | Out-Null
}

function Write-SerenaDebug {
  param([string]$Message)
  if ($env:SERENA_DEBUG -and $env:SERENA_DEBUG -in @('1','true','True')) {
    Write-Host "[serena][debug] $Message"
  }
}


