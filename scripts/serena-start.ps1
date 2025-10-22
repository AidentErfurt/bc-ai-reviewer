param()

$ErrorActionPreference = 'Stop'

# Ensure local bin on PATH
"$HOME/.local/bin" | Out-File -FilePath $env:GITHUB_PATH -Append -Encoding ascii
$env:PATH = "$HOME/.local/bin" + [IO.Path]::PathSeparator + $env:PATH

# Use Python 3.11 (provided by setup-python step)
$pyDir = $env:pythonLocation
if (-not $pyDir) { throw "pythonLocation env var not set by setup-python." }
$py = Join-Path $pyDir "bin/python"

# Install pipx + Serena
& $py -m pip install --user --upgrade pip pipx | Out-String | Write-Host
& $py -m pipx ensurepath | Out-String | Write-Host
& $py -m pipx install --python "$py" "git+https://github.com/oraios/serena" | Out-String | Write-Host

$serena = Get-Command serena -ErrorAction Stop
Write-Host "Serena binary: $($serena.Source)"

# Start HTTP MCP server
$port = 5173
$base = "http://127.0.0.1:$port"
$SerenaUrl = "$base/mcp"
$out = "/tmp/serena_http.out"
$err = "/tmp/serena_http.err"

$proc = Start-Process -FilePath "serena-mcp-server" `
  -ArgumentList @(
    '--transport','streamable-http',
    '--port',"$port",
    '--context','ide-assistant'
  ) `
  -WorkingDirectory $env:GITHUB_WORKSPACE `
  -PassThru -NoNewWindow `
  -RedirectStandardOutput $out -RedirectStandardError $err
$SerenaPid = $proc.Id
"$SerenaPid" | Out-File /tmp/serena_http.pid -Encoding ascii
Write-Host "Serena PID: $SerenaPid"

# Wait until listener is alive
$deadline = (Get-Date).AddSeconds(25)
$ready = $false
do {
  try {
    Invoke-WebRequest -Uri "$base/mcp" -Method GET -Headers @{Accept='text/event-stream'} -TimeoutSec 2 -SkipHttpErrorCheck | Out-Null
    $ready = $true
  } catch {
    if ($proc.HasExited) {
      Write-Host "-- serena stdout (tail) --"; if (Test-Path $out) { Get-Content $out -Tail 150 }
      Write-Host "-- serena stderr (tail) --"; if (Test-Path $err) { Get-Content $err -Tail 150 }
      throw "Serena process exited before HTTP became ready."
    }
    Start-Sleep -Milliseconds 300
  }
} while (-not $ready -and (Get-Date) -lt $deadline)

if (-not $ready) {
  Write-Host "-- serena stdout (tail) --"; if (Test-Path $out) { Get-Content $out -Tail 150 }
  Write-Host "-- serena stderr (tail) --"; if (Test-Path $err) { Get-Content $err -Tail 150 }
  throw "Serena HTTP endpoint didn’t become reachable at $base/mcp."
}

# Export local URL for subsequent steps
"SERENA_URL=$SerenaUrl" | Out-File -FilePath $env:GITHUB_ENV -Append -Encoding ascii
