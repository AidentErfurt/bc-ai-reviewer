# PowerShell .github/actions/continue/merge-config.ps1
<#
  Merge helper (PowerShell)
  - Reads default-config.yaml shipped with the action
  - Replaces the top-level `models:` block with the MODELS_BLOCK environment variable (if provided)
  - Performs placeholder substitution: {{NAME}} -> $env:NAME
  - Writes merged config to --out <path>

Usage (from GitHub Actions step, shell: pwsh):
  $env:MODELS_BLOCK = "${{ inputs.MODELS_BLOCK }}

  & "${{ github.action_path }}/.github/actions/continue/merge-config.ps1" --out $mergeOut
#>

param(
  [Parameter(Mandatory=$false)][string]$out
)

function UsageAndExit([string]$msg) {
  if ($msg) { Write-Error $msg }
  Write-Host "Usage: merge-config.ps1 --out /path/to/out.yaml"
  exit 1
}

if (-not $out) { UsageAndExit 'Missing --out argument' }

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$defaultCfgPath = Join-Path $scriptDir 'default-config.yaml'

if (-not (Test-Path $defaultCfgPath)) {
  Write-Error "default-config.yaml not found at $defaultCfgPath"
  exit 2
}

try {
  $defaultText = Get-Content -Raw -Path $defaultCfgPath -ErrorAction Stop
} catch {
  Write-Error "Failed reading default-config.yaml: $_"
  exit 3
}

$modelsBlock = $env:MODELS_BLOCK
if (-not $modelsBlock -or $modelsBlock.Trim().Length -eq 0) {
  # No replacement requested â€” copy default config
  try {
    Set-Content -Path $out -Value $defaultText -Encoding UTF8
    Write-Host "Wrote default config to $out"
    exit 0
  } catch {
    Write-Error "Failed to write output file: $_"
    exit 4
  }
}

# Normalize provided block
$mb = $modelsBlock.Trim()

# If user provided a list starting with '-' or a model object without top-level 'models:',
# wrap it under a models: key. If the block is a single model mapping (no leading '-'),
# convert it into a YAML list item so `models:` becomes a sequence of model mappings.
if (-not ($mb -match '(?m)^\s*models:\s*')) {
  if ($mb.TrimStart().StartsWith('-')) {
    # Already a YAML sequence of models (each starting with '-'), just prepend models:
    $mb = "models:`n" + $mb
  } else {
    # Convert single model mapping into a list item under models:
    $lines = [regex]::Split($mb, "\r?\n")
    # find first non-empty line index
    $firstIdx = 0
    for ($i=0; $i -lt $lines.Length; $i++) {
      if ($lines[$i].Trim().Length -gt 0) { $firstIdx = $i; break }
    }
    # prepend '- ' to the first non-empty line and indent subsequent lines by two spaces
    $outLines = @()
    for ($i=0; $i -lt $lines.Length; $i++) {
      $line = $lines[$i]
      if ($i -eq $firstIdx) {
        $outLines += ("- " + $line.TrimStart())
      } else {
        $outLines += ("  " + $line)
      }
    }
    $mb = "models:`n" + ($outLines -join "`n")
  }
}

# Helper: substitute placeholders {{NAME}} with env var values
function SubstitutePlaceholders([string]$text) {
  return [regex]::Replace($text, '\{\{\s*([A-Z0-9_]+)\s*\}\}', {
    param($m)
    $name = $m.Groups[1].Value
    $val = (Get-Item -Path env:$name -ErrorAction SilentlyContinue).Value
    if ($null -eq $val) {
      # If not set, replace with empty string to avoid leaking placeholder into produced file.
      return ''
    }
    return $val
  })
}

# Perform substitution on the models block itself
$mb = SubstitutePlaceholders $mb

# Helper: write a redacted copy of the merged config for debugging (hides secrets)
function Write-RedactedConfig([string]$outPath, [string]$text) {
  try {
    # Redact common sensitive keys (case-insensitive): apiKey, apikey, api_key, key, secret, token, password
    $pattern = '(?im)^(\s*[^:\n]*?(?:api[-_ ]?key|apikey|apiBase|apiKey|api_key|key|secret|token|password)\s*:\s*)(.+)$'
    $redacted = [regex]::Replace($text, $pattern, '${1} "***REDACTED***"')

    # Additionally redact any values that look like long opaque tokens ( > 40 non-whitespace chars )
    $redacted = [regex]::Replace($redacted, '(?m)(^\s*[^:]+:\s*)([A-Za-z0-9_\-\.=]{40,})', '${1} "***REDACTED***"')

    $redPath = $outPath + '.redacted'
    Set-Content -Path $redPath -Value $redacted -Encoding UTF8 -ErrorAction Stop
    Write-Host "Wrote redacted config to $redPath"

    # Only print the redacted contents if explicitly enabled (avoid leaking secrets in logs)
    if ($env:CONTINUE_SHOW_REDACTED -eq '1') {
      Write-Host "===== Redacted merged continue-config.yaml ====="
      Get-Content -Raw -Path $redPath | Write-Host
      Write-Host "===== End redacted config ====="
    }
  } catch {
    Write-Warning "Failed to write/print redacted config: $_"
  }
}

# Find the existing models: start in the default text
$modelsStartRegex = '(?m)^[ \t]*models:\s*$'
$startMatch = [regex]::Match($defaultText, $modelsStartRegex)
if (-not $startMatch.Success) {
  # No models key â€” append
  $outText = $defaultText.TrimEnd() + "`n`n" + $mb.Trim() + "`n"
  $outText = SubstitutePlaceholders $outText
  try {
    Set-Content -Path $out -Value $outText -Encoding UTF8
    Write-Host "Appended models block to default config and wrote to $out"
    # Also write a redacted copy for debugging (no secrets)
    Write-RedactedConfig -outPath $out -text $outText
    exit 0
  } catch {
    Write-Error "Failed to write output file: $_"
    exit 5
  }
}

$startIndex = $startMatch.Index

# Find next top-level key after the models: line
$topLevelRegex = '(?m)^[A-Za-z0-9_-]+:'
$matches = [regex]::Matches($defaultText, $topLevelRegex)
$endIndex = $null
$foundStart = $false
foreach ($m in $matches) {
  if (-not $foundStart) {
    if ($m.Index -ge $startIndex) {
      # This is the models: match itself; mark found and continue
      $foundStart = $true
      continue
    }
  } else {
    # first top-level entry after models:
    $endIndex = $m.Index
    break
  }
}
if ($null -eq $endIndex) {
  $endIndex = $defaultText.Length
}

$before = $defaultText.Substring(0, $startIndex)
$remainder = $defaultText.Substring($endIndex)

$outText = $before.TrimEnd() + "`n`n" + $mb.Trim() + "`n`n" + $remainder.TrimStart() + "`n"

# Substitute placeholders in the whole file too (in case other placeholders exist)
$outText = SubstitutePlaceholders $outText

try {
  Set-Content -Path $out -Value $outText -Encoding UTF8
  Write-Host "Wrote merged config with replacement models block to $out"
  # Also write a redacted copy for debugging (no secrets)
  Write-RedactedConfig -outPath $out -text $outText
  exit 0
} catch {
  Write-Error "Failed to write output file: $_"
  exit 6
}
