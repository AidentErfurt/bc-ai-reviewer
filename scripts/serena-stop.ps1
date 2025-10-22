param()

$ErrorActionPreference = 'SilentlyContinue'

if (Test-Path /tmp/serena_http.pid) {
  $SerenaPid = Get-Content /tmp/serena_http.pid
  if ($SerenaPid) {
    Write-Host "Stopping Serena PID $SerenaPid"
    try { Stop-Process -Id $SerenaPid -ErrorAction SilentlyContinue } catch {}
  }
}
