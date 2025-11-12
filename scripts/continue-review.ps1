<#
  Continue + MCP PR reviewer for Business Central AL

  Key differences vs. v1:
  - Uses Continue CLI headless review configured via CONTINUE_CONFIG (Hub/local).
  - First posts the summary as its own review (cannot be invalidated by inline failures).
  - Then posts each inline comment individually; failed anchors fall back to file-level notes.
  - Maps to diff lines robustly using parse-diff, favoring RIGHT/ln2 (HEAD) numbers.

  Requirements in Action step:
    npm i -g @continuedev/cli
    npm i --no-save parse-diff
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$GitHubToken,
  [int]$MaxComments = 10,
  [string]$ProjectContext = "",
  [string]$ContextFiles = "",
  [string]$IncludePatterns = "**/*.al,**/*.xlf,**/*.json",
  [string]$ExcludePatterns = "",
  [int]$IssueCount = 0,
  [bool]$FetchClosedIssues = $true,
  [bool]$AutoDetectApps = $true,
  [bool]$IncludeAppPermissions = $true,
  [bool]$IncludeAppMarkdown = $true,
  [string]$BasePromptExtra = "",
  [switch]$ApproveReviews,
  [switch]$LogPrompt
)

############################################################################
# HTTP helpers
############################################################################
function Invoke-GitHub {
  param(
    [string]$Method = 'GET',
    [string]$Path,
    [object]$Body = $null,
    [string]$Accept = 'application/vnd.github+json'
  )
  $uri = "https://api.github.com$Path"
  $hdr = @{
    Authorization         = "Bearer $GitHubToken"
    Accept                = $Accept
    'X-GitHub-Api-Version'= '2022-11-28'
    'User-Agent'          = 'bc-ai-reviewer-continue'
  }
  if ($Body) { $Body = $Body | ConvertTo-Json -Depth 100 }
  Invoke-RestMethod -Method $Method -Uri $uri -Headers $hdr -Body $Body
}

function Get-PR {
  param([string]$Owner, [string]$Repo, [int]$PrNumber)
  Invoke-GitHub -Path "/repos/$Owner/$Repo/pulls/$PrNumber"
}

function Get-PRDiff {
  param([string]$Owner, [string]$Repo, [int]$PrNumber)
  # Request full PR diff (unified)
  Invoke-GitHub -Path "/repos/$Owner/$Repo/pulls/$PrNumber" -Accept 'application/vnd.github.v3.diff'
}

function Get-PRFiles {
  param([string]$Owner, [string]$Repo, [int]$PrNumber)
  $page = 1; $all = @()
  do {
    $resp = Invoke-GitHub -Path "/repos/$Owner/$Repo/pulls/$PrNumber/files?per_page=100&page=$page"
    $all += $resp
    $page++
  } while ($resp.Count -eq 100)
  $all
}

function Get-FileContent {
  param([string]$Owner,[string]$Repo,[string]$Path,[string]$RefSha)
  try {
    $blob = Invoke-GitHub -Path "/repos/$Owner/$Repo/contents/$Path?ref=$RefSha"
    if ($blob.content) {
      $bytes = [Convert]::FromBase64String($blob.content)
      [System.Text.Encoding]::UTF8.GetString($bytes)
    }
  } catch { $null }
}

############################################################################
# Repo / PR discovery
############################################################################
$ErrorActionPreference = 'Stop'

$owner, $repo = $env:GITHUB_REPOSITORY.Split('/')
$evt = Get-Content $env:GITHUB_EVENT_PATH -Raw | ConvertFrom-Json
if (-not $evt.pull_request) { Write-Warning "No pull_request payload. Exiting."; return }
$prNumber = $evt.pull_request.number
$pr = Get-PR -Owner $owner -Repo $repo -PrNumber $prNumber
$headSha = $pr.head.sha

Write-Host "Reviewing PR #$prNumber in $owner/$repo @ $headSha"

############################################################################
# Get unified diff and parse with parse-diff (Node)
############################################################################
$patch = Get-PRDiff -Owner $owner -Repo $repo -PrNumber $prNumber
if (-not $patch) { Write-Host "Empty diff; exiting."; return }

$js = Join-Path $PSScriptRoot 'parse-diff.js'
if (-not (Test-Path $js)) {
  throw "parse-diff helper not found at '$js'. Ensure scripts/parse-diff.js is present in the repository and the action step installs the npm package 'parse-diff' (npm install --no-save parse-diff)."
}

$pdOut = $patch | node $js 2>&1
if ($LASTEXITCODE -ne 0) { throw "parse-diff failed: $pdOut" }
$files = @($pdOut | ConvertFrom-Json) | Where-Object { $_ }
if (-not $files.Count) { Write-Host "No changed files; exiting."; return }

# Filter by include/exclude globs
$inc = $IncludePatterns -split ',' | % { $_.Trim() } | ? { $_ }
$exc = $ExcludePatterns -split ',' | % { $_.Trim() } | ? { $_ }
$compiledIncludes = $inc | ForEach-Object { [System.Management.Automation.WildcardPattern]::Get($_,[System.Management.Automation.WildcardOptions]::IgnoreCase) }
$compiledExcludes = $exc | ForEach-Object { [System.Management.Automation.WildcardPattern]::Get($_,[System.Management.Automation.WildcardOptions]::IgnoreCase) }

$relevant = @(
  $files | Where-Object {
    $p = $_.path
    ((@($compiledIncludes | ? { $_.IsMatch($p) })).Count -gt 0) -and
    ((@($compiledExcludes | ? { $_.IsMatch($p) })).Count -eq 0)
  }
)
if (-not $relevant) { Write-Host "No relevant files after globs; exiting."; return }

# Build commentable line whitelist (HEAD/right only), and number-prefixed diffs
$validLines = @{}
$numberedFiles = foreach ($f in $relevant) {
  $lines = foreach ($chunk in $f.chunks) {
    foreach ($chg in $chunk.changes) {
      if ($chg.ln2) { "{0} {1}" -f $chg.ln2, $chg.content }
    }
  }
  $validLines[$f.path] = @(
    foreach ($chunk in $f.chunks) {
      foreach ($chg in $chunk.changes) {
        if ($chg.ln2) { [int]$chg.ln2 }
      }
    }
  ) | Sort-Object -Unique

  [pscustomobject]@{
    path = $f.path
    diff = ($lines -join "`n")
  }
}

############################################################################
# Optional: gather app context and extra globs
############################################################################
$ctxFiles = @()
if ($AutoDetectApps) {
  $repoRoot = $Env:GITHUB_WORKSPACE
  $allAppJsons = @(Get-ChildItem -Path $repoRoot -Recurse -Filter 'app.json' | % { $_.FullName.Replace('\','/') })
  $relevantApps = @{}
  foreach ($f in $relevant) {
    $full = Join-Path $repoRoot $f.path
    $dir = Split-Path $full -Parent
    while ($dir) {
      $candidate = (Join-Path $dir 'app.json').Replace('\','/')
      if ($allAppJsons -contains $candidate) { $relevantApps[$candidate] = $true; break }
      $parent = Split-Path $dir -Parent; if ($parent -eq $dir) { break } ; $dir = $parent
    }
  }
  foreach ($appJson in $relevantApps.Keys) {
    $appRoot = Split-Path $appJson -Parent
    $rel = [IO.Path]::GetRelativePath($repoRoot,$appJson) -replace '\\','/'
    $ctxFiles += [pscustomobject]@{ path=$rel; content=(Get-Content $appJson -Raw) }
    if ($IncludeAppPermissions) {
      Get-ChildItem -Path $appRoot -Recurse -Include '*.PermissionSet.al','*.Entitlement.al' | % {
        $relp = [IO.Path]::GetRelativePath($repoRoot,$_.FullName) -replace '\\','/'
        $ctxFiles += [pscustomobject]@{ path=$relp; content=(Get-Content $_.FullName -Raw) }
      }
    }
    if ($IncludeAppMarkdown) {
      Get-ChildItem -Path $appRoot -Recurse -Filter '*.md' | % {
        $relm = [IO.Path]::GetRelativePath($repoRoot,$_.FullName) -replace '\\','/'
        $ctxFiles += [pscustomobject]@{ path=$relm; content=(Get-Content $_.FullName -Raw) }
      }
    }
  }
}

# Custom context globs (from repo HEAD)
$ctxGlobs = $ContextFiles -split ',' | % { $_.Trim() } | ? { $_ }
foreach ($glob in $ctxGlobs) {
  try {
    $blob = Invoke-GitHub -Path "/repos/$owner/$repo/contents/$($glob)?ref=$headSha"
    if ($blob.content) {
      $ctxFiles += [pscustomobject]@{
        path    = $glob
        content = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($blob.content))
      }
    }
  } catch { Write-Warning "Could not fetch context '$glob': $_" }
}

############################################################################
# Build Continue prompt
############################################################################
$maxInline = if ($MaxComments -gt 0) { $MaxComments } else { 1000 }

$reviewContract = @"
You are reviewing **Business Central AL** code changes. Use BC best practices (CodeCop/UICop/AppSourceCop, data classification, permissions, events, performance patterns) and keep inline remarks short (≤3 lines). 

Output **only this JSON** (no fences):

{
  "summary": "Markdown summary for the PR (positives, risks, key findings, actionable next steps).",
  "comments": [
    { "path": "path/in/repo.al", "line": 123, "body": "Short remark followed by a ```suggestion
...replacement...
``` block when appropriate." }
  ],
  "suggestedAction": "approve" | "request_changes" | "comment",
  "confidence": 0.0-1.0
}

Constraints:
- Choose `" + 'line' + @"` numbers **only from** the `validLines` table for each file (these are HEAD/RIGHT line numbers from the diff).
- At most $maxInline comments; aggregate overflow into the summary.
- Keep suggestion replacements small (≤6 lines).
- Do not reference contextFiles in inline comments; they’re for reasoning only.
$BasePromptExtra
"@

$payload = @{
  files       = $numberedFiles
  validLines  = $validLines
  contextFiles= $ctxFiles
  pullRequest = @{
    title = $pr.title
    description = $pr.body
    base = $pr.base.sha
    head = $pr.head.sha
  }
  projectContext = $ProjectContext
}

$tempPrompt = Join-Path $env:RUNNER_TEMP 'continue_prompt.txt'
$tempJson   = Join-Path $env:RUNNER_TEMP 'continue_input.json'
$payload | ConvertTo-Json -Depth 8 | Set-Content -Path $tempJson -Encoding UTF8

# Build a single prompt text (reviewContract + machine-readable section)
@"
$reviewContract

## DIFF (numbered)
$(( $numberedFiles | ConvertTo-Json -Depth 6 ))

## VALID LINES
$(( $validLines | ConvertTo-Json -Depth 6 ))

## CONTEXT FILES (truncated as needed)
$(( @($ctxFiles | Select-Object -First 30) | ConvertTo-Json -Depth 4 ))
"@ | Set-Content -Path $tempPrompt -Encoding UTF8

if ($LogPrompt) {
  Write-Host "::group::Prompt preview"
  Get-Content $tempPrompt -Raw | Write-Host
  Write-Host "::endgroup::"
}

############################################################################
# Continue runner (single impl) — slug-only, no URL rewriting, stable Hub base
############################################################################
# ---------- Resolve merged config file (from composite action) ----------
$cfgRaw = if ($env:CONTINUE_CONFIG) { $env:CONTINUE_CONFIG } else { throw "CONTINUE_CONFIG not set. The composite action must set CONTINUE_CONFIG to the merged local config path." }
if (-not (Test-Path -LiteralPath $cfgRaw)) { throw "CONTINUE_CONFIG path not found: '$cfgRaw'" }
$cfg = $cfgRaw


# --- Sanitize URL-like provider env vars that commonly cause `401 "Invalid URL"` ---
function Remove-EmptyUrlEnv {
  param([string[]]$Names)
  $removed = @()
  foreach ($n in $Names) {
    $v = [Environment]::GetEnvironmentVariable($n)
    if ($null -ne $v) {
      if ([string]::IsNullOrWhiteSpace($v)) {
        [Environment]::SetEnvironmentVariable($n, $null) # unset
        $removed += $n
      } elseif ($v -notmatch '^(https?://)') {
        # value present but not an http(s) URL — many SDKs error with "Invalid URL"
        [Environment]::SetEnvironmentVariable($n, $null)
        $removed += $n
      }
    }
  }
  return $removed
}

# Known provider URL/endpoint variables across OpenAI/Azure/etc.
$likelyUrlVars = @(
  'OPENAI_API_BASE','OPENAI_BASE_URL','OPENAI_API_HOST',
  'AZURE_OPENAI_ENDPOINT','AZURE_OPENAI_BASE',
  'ANTHROPIC_API_URL','ANTHROPIC_BASE_URL',
  'COHERE_BASE_URL','COHERE_API_BASE',
  'MISTRAL_API_BASE','MISTRAL_BASE_URL',
  'GROQ_API_BASE','GROQ_BASE_URL',
  'TOGETHER_BASE_URL','TOGETHER_API_BASE'
)

# Also catch any *_BASE_URL / *_ENDPOINT left blank by the runner
$dynamicUrlVars = [Environment]::GetEnvironmentVariables().Keys |
  Where-Object { $_ -match '(_BASE_URL|_ENDPOINT)$' }

$removedVars = Remove-EmptyUrlEnv -Names ($likelyUrlVars + $dynamicUrlVars | Sort-Object -Unique)
if ($removedVars.Count -gt 0) {
  Write-Warning ("Unset empty/malformed URL env vars to avoid provider errors: {0}" -f ($removedVars -join ', '))
}

# ---------- Helpers ----------
function Get-JsonFromText {
  param([Parameter(Mandatory)][string]$Text)
  $clean = $Text.Trim()
  $clean = $clean -replace '^\s*```json\s*', ''
  $clean = $clean -replace '^\s*```\s*', ''
  $clean = $clean -replace '\s*```\s*$', ''
  $clean = $clean -replace '\\(?!["\\/bfnrtu])','\\'
  try { return $clean | ConvertFrom-Json -ErrorAction Stop } catch {
    $m = [regex]::Match($clean, '{[\s\S]*}')
    if ($m.Success) {
      $frag = $m.Value -replace '\\(?!["\\/bfnrtu])','\\'
      try { return $frag | ConvertFrom-Json -ErrorAction Stop } catch {}
    }
    throw "Could not parse JSON from model output.`n--- Raw start ---`n$Text`n--- Raw end ---"
  }
}

# ---------- Single CLI runner (stdin feed; no slug->URL conversion) ----------
function Invoke-ContinueCli {
  param(
    [Parameter(Mandatory)][string]$Config,  # slug or local file
    [Parameter(Mandatory)][string]$Prompt
  )

  if (-not $env:CONTINUE_LOG_LEVEL) { $env:CONTINUE_LOG_LEVEL = "debug" }

  Write-Host "::group::Continue CLI environment"
  try { $cnVer = (& cn --version) 2>&1 } catch { throw "Continue CLI (cn) not found on PATH." }
  Write-Host "cn --version:`n$cnVer"
  Write-Host "CONTINUE_CONFIG (file): $Config"
  Write-Host "::endgroup::"

  # Write prompt to a temp file
  $tempPromptFile = Join-Path $env:RUNNER_TEMP 'continue_prompt.txt'
  $Prompt | Set-Content -Path $tempPromptFile -Encoding UTF8

  Write-Host "Running Continue CLI..."

  # Invoke Continue CLI and capture its combined output directly (local configs only)
  $cnOutput = & cn --config $Config -p (Get-Content -Raw $tempPromptFile) --auto 2>&1

  # Known raw log location (Continue may still write its own raw log)
  $runTemp = $env:RUNNER_TEMP
  $contRaw = Join-Path $runTemp 'continue_cli_raw.log'

  # Copy raw log to workspace so upload-artifact (next step) can pick it up if present
  $logDir = Join-Path $env:GITHUB_WORKSPACE '.continue-logs'
  New-Item -ItemType Directory -Force -Path $logDir | Out-Null

  $copied = @()
  if (Test-Path $contRaw) {
    Copy-Item $contRaw -Destination (Join-Path $logDir (Split-Path $contRaw -Leaf)) -Force
    $copied += (Join-Path $logDir (Split-Path $contRaw -Leaf))
  }

    if ($copied.Count -gt 0) {
    Write-Host ("Logs copied for upload: " + ($copied -join ', '))
    } else {
    Write-Warning "No Continue logs were found to copy."
    }

  $exit = $LASTEXITCODE
  $stdout = ($cnOutput -join "`n")
  $stderr = ""

  # Continue CLI often writes its own raw log here; show users where to look
  $contRaw = Join-Path $env:RUNNER_TEMP 'continue_cli_raw.log'
  if (Test-Path $contRaw) {
    Write-Host ("Continue raw log: " + $contRaw)
  }

  if ($exit -ne 0) {
    # Try to parse structured JSON error if present; otherwise surface stderr + log path
    try {
      $errJson = $stdout | ConvertFrom-Json -ErrorAction Stop
      if ($errJson.status -and $errJson.message) {
        throw ("Continue CLI failed (exit {0}): {1}: {2}" -f $exit, $errJson.status, $errJson.message)
      }
    } catch { }

    $hint = (Test-Path $contRaw) ? " Full raw log: $contRaw" : ""
    throw ("Continue CLI failed (exit {0}).{1}" -f $exit, $hint)
  }

  # Extract JSON from model output (same logic you had, but run on $stdout)
  return Get-JsonFromText -Text $stdout
}


# ---------- Execute ----------
$promptText = Get-Content $tempPrompt -Raw
Write-Host "Resolved Continue config file: '$cfg'"
try {
  $review = Invoke-ContinueCli -Config $cfg -Prompt $promptText
} catch {
  throw "Continue run failed: $($_.Exception.Message)"
}


############################################################################
# Post summary as a safe, standalone review first
############################################################################
$event = 'COMMENT'
if ($ApproveReviews.IsPresent) {
  switch ($review.suggestedAction) {
    'approve'         { $event = 'APPROVE' }
    'request_changes' { $event = 'REQUEST_CHANGES' }
    default           { $event = 'COMMENT' }
  }
}
# Footer to credit engine/config (non-blocking)
$footer = "`n`n---`n_Review powered by [Continue](https://continue.dev). Config: **$cfg**_"
$summaryBody = ($review.summary ?? "Automated review") + $footer

$summaryResp = Invoke-GitHub -Method POST -Path "/repos/$owner/$repo/pulls/$prNumber/reviews" -Body @{
  body      = $summaryBody
  event     = $event
  commit_id = $headSha
}
Write-Host "Summary review posted."

############################################################################
# Post inline comments individually (robust). Fallback to file-level.
############################################################################
$posted = 0
$comments = @($review.comments) | Where-Object { $_ } 
if ($MaxComments -gt 0 -and $comments.Count -gt $MaxComments) {
  $comments = $comments[0..($MaxComments-1)]
}

# Build per-file side map & whitelist from parse-diff output (RIGHT only)
$sideMap  = @{}
foreach ($f in $relevant) {
  $sides = @{}
  foreach ($chunk in $f.chunks) {
    foreach ($chg in $chunk.changes) {
      if ($chg.ln2) { $sides[[int]$chg.ln2] = 'RIGHT' }
    }
  }
  $sideMap[$f.path] = $sides
}

foreach ($c in $comments) {
  $path = $c.path
  $line = [int]$c.line
  $body = [string]$c.body
  if (-not $path -or -not $body) { continue }

  $whitelist = $validLines[$path]
  $sideFor   = $sideMap[$path]

  $bodyFinal = $body
  if ($bodyFinal -notmatch '```suggestion') {
    # allow non-suggestion remarks; keep short
    $bodyFinal = $body
  }

  $ok = $false
  if ($whitelist -and $whitelist -contains $line -and $sideFor[$line]) {
    try {
      $resp = Invoke-GitHub -Method POST -Path "/repos/$owner/$repo/pulls/$prNumber/comments" -Body @{
        body      = $bodyFinal
        commit_id = $headSha
        path      = $path
        line      = $line
        side      = 'RIGHT'
      }
      $posted++
      $ok = $true
    } catch {
      $msg = $_.Exception.Message
      if ($msg -match 'line must be part of the diff|Validation Failed') {
        $ok = $false
      } else { throw }
    }
  }

  if (-not $ok) {
    # Fallback: file-level comment (no "Apply suggestion" button, but preserves feedback)
    try {
      $note = "$bodyFinal`n`n> _Could not anchor to diff line; posting as file-level note._"
      $resp = Invoke-GitHub -Method POST -Path "/repos/$owner/$repo/pulls/$prNumber/comments" -Body @{
        body         = $note
        commit_id    = $headSha
        path         = $path
        subject_type = 'file'
      }
      $posted++
    } catch {
      Write-Warning "Failed to post comment for $($path):$line - $($_.Exception.Message)"
    }
  }
}

Write-Host "Posted $posted inline/file-level comments."
Write-Host "Done."
