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

# Ensure helper file exists (we vendor a tiny wrapper)
$js = Join-Path $PSScriptRoot 'parse-diff.js'
if (-not (Test-Path $js)) {
  @'
const fs = require("fs");
let parse;
try { parse = require("parse-diff"); }
catch {
  const { createRequire } = require("module");
  const cwdRequire = createRequire(process.cwd() + "/");
  parse = cwdRequire("parse-diff");
}
let buf = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", c => buf += c);
process.stdin.on("end", () => {
  try {
    const files = parse(buf || "");
    process.stdout.write(JSON.stringify(files));
  } catch (e) {
    console.error(e?.stack || e?.message || String(e));
    process.exit(1);
  }
});
'@ | Set-Content -Path $js -Encoding UTF8
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
# PowerShell-only Continue runner (slug-only; no URL conversion, extra debug)
############################################################################
function Get-JsonFromText {
  param([Parameter(Mandatory)][string]$Text)
  $clean = $Text.Trim()
  $clean = $clean -replace '^\s*```json\s*', ''
  $clean = $clean -replace '^\s*```\s*', ''
  $clean = $clean -replace '\s*```\s*$', ''
  $clean = $clean -replace '\\(?!["\\/bfnrtu])','\\'
  try {
    return $clean | ConvertFrom-Json -ErrorAction Stop
  } catch {
    $m = [regex]::Match($clean, '{[\s\S]*}')
    if ($m.Success) {
      $frag = $m.Value -replace '\\(?!["\\/bfnrtu])','\\'
      try { return $frag | ConvertFrom-Json -ErrorAction Stop } catch {}
    }
    throw "Could not parse JSON from model output.`n--- Raw start ---`n$Text`n--- Raw end ---"
  }
}

function Assert-ContinueSlug {
  param([Parameter(Mandatory)][string]$Value)
  if ($Value -match '^(https?)://') {
    throw "CONTINUE_CONFIG must be a slug ('owner/package'), not a URL. Got: $Value"
  }
  if ($Value -notmatch '^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$') {
    throw "Invalid CONTINUE_CONFIG format. Expected 'owner/package'. Got: $Value"
  }
  return $Value
}

function Invoke-ContinueCli {
  param(
    [Parameter(Mandatory)][string]$Slug,
    [Parameter(Mandatory)][string]$Prompt
  )
  # Hard set noisy logging if you want, or honor existing
  if (-not $env:CONTINUE_LOG_LEVEL) { $env:CONTINUE_LOG_LEVEL = "debug" }

  Write-Host "::group::Continue CLI environment"
  try { Write-Host "cn --version:`n$(& cn --version 2>&1)" } catch { Write-Host "cn --version failed: $($_.Exception.Message)" }
  Write-Host "CONTINUE_CONFIG (raw/slug): $Slug"
  if ($env:CONTINUE_HUB_URL) { Write-Host "CONTINUE_HUB_URL: $env:CONTINUE_HUB_URL" } else { Write-Host "CONTINUE_HUB_URL: [not set]" }
  Write-Host "CONTINUE_API_KEY: " + ($(if ($env:CONTINUE_API_KEY) { "[set]" } else { "[missing]" }))
  Write-Host "::endgroup::"

  # Write prompt to a temp file (don’t echo it)
  $tempPromptFile = Join-Path $env:RUNNER_TEMP 'continue_prompt.txt'
  $Prompt | Set-Content -Path $tempPromptFile -Encoding UTF8
  $promptArg = Get-Content -Raw -Path $tempPromptFile

  Write-Host "Running Continue CLI (argument-passed prompt) ..."
  $psi = [System.Diagnostics.ProcessStartInfo]::new()
  $psi.FileName = 'cn'
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError  = $true

  $null = $psi.ArgumentList.Add('--config')
  $null = $psi.ArgumentList.Add($Slug)            # IMPORTANT: slug only
  $null = $psi.ArgumentList.Add('-p')
  $null = $psi.ArgumentList.Add($promptArg)
  $null = $psi.ArgumentList.Add('--auto')

  $p = [System.Diagnostics.Process]::new()
  $p.StartInfo = $psi
  [void]$p.Start()
  $stdOut = $p.StandardOutput.ReadToEnd()
  $stdErr = $p.StandardError.ReadToEnd()
  $p.WaitForExit()

  if ($p.ExitCode -ne 0) {
    $snippet = ($stdErr + "`n" + $stdOut)
    if ($snippet.Length -gt 4000) { $snippet = $snippet.Substring(0,4000) + "`n...[truncated]..." }
    throw ("Continue CLI failed (exit {0}):`n{1}" -f $p.ExitCode, $snippet)
  }

  $combined = if ([string]::IsNullOrWhiteSpace($stdOut)) { $stdErr } else { $stdOut }
  return Get-JsonFromText -Text $combined
}

# ---------- Resolve config (Hub slug or local) ----------
# Accept only "owner/package" or a local file path. Never rewrite to a URL.
$cfgRaw = if ($env:CONTINUE_CONFIG) { $env:CONTINUE_CONFIG } else { "continuedev/review-bot" }

# Fail fast if someone passed a URL.
if ($cfgRaw -match '^\s*https?://') {
  throw "CONTINUE_CONFIG must be a slug like 'owner/package' or a local path. Got URL: '$cfgRaw'"
}

# Allow local file path (.json/.yaml/.yml) or slug owner/package
$cfgIsFile = Test-Path -LiteralPath $cfgRaw
if (-not $cfgIsFile -and ($cfgRaw -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')) {
  throw "Invalid CONTINUE_CONFIG. Expected 'owner/package' or a local config file. Got: '$cfgRaw'"
}

$cfg = $cfgRaw  # keep exactly as given

# Optional: honor CONTINUE_HUB_URL only if explicitly set by the workflow/user
# (We do NOT invent one. The CLI's default is the public Hub.)
if ($env:CONTINUE_HUB_URL) {
  Write-Host "Using CONTINUE_HUB_URL (user-provided): $($env:CONTINUE_HUB_URL)"
}

# ---------- Enhanced CLI runner with detailed logging ----------
function Invoke-ContinueCli {
  param(
    [Parameter(Mandatory)][string]$Config,
    [Parameter(Mandatory)][string]$Prompt
  )

  # Verbose logging to help debug Hub/assistant issues
  if (-not $env:CONTINUE_LOG_LEVEL) { $env:CONTINUE_LOG_LEVEL = "debug" }

  # Preflight: show exactly what cn will see (without secrets)
  Write-Host "::group::Continue CLI environment"
  try {
    $cnVer = (& cn --version) 2>&1
  } catch {
    throw "Continue CLI (cn) not found on PATH."
  }
  Write-Host "cn --version:`n$cnVer"
  Write-Host "CONTINUE_CONFIG (raw): $Config"
  Write-Host ("CONTINUE_HUB_URL: " + ($(if ($env:CONTINUE_HUB_URL) { $env:CONTINUE_HUB_URL } else { "[not set]" })))
  Write-Host ("CONTINUE_API_KEY: " + ($(if ($env:CONTINUE_API_KEY) { "[set]" } else { "[not set]" })))
  Write-Host "::endgroup::"

  # Write prompt to a temp file and feed via stdin (avoids arg length issues)
  $tempPromptFile = Join-Path $env:RUNNER_TEMP 'continue_prompt.txt'
  $Prompt | Set-Content -Path $tempPromptFile -Encoding UTF8

  Write-Host "Running Continue CLI (argument-passed prompt) ..."
  # Capture combined stdout/stderr; also tee to a temp log for postmortem
  $tempLog = Join-Path $env:RUNNER_TEMP 'continue_cli_raw.log'
  $raw = Get-Content -Raw -Path $tempPromptFile |
         & cn --config $Config -p - --auto 2>&1
  $exit = $LASTEXITCODE
  ($raw -is [array] ? ($raw -join "`n") : [string]$raw) | Set-Content -Path $tempLog -Encoding UTF8

  if ($exit -ne 0) {
    # Try to surface any structured error JSON the CLI produced
    $rawText = Get-Content -Raw -Path $tempLog
    $errJson = $null
    try { $errJson = $rawText | ConvertFrom-Json -ErrorAction Stop } catch {}
    if ($errJson -and $errJson.status -and $errJson.message) {
      throw ("Continue CLI failed (exit {0}): {1}: {2}" -f $exit, $errJson.status, $errJson.message)
    } else {
      throw ("Continue CLI failed (exit {0}). See raw log at: {1}`n--- RAW START ---`n{2}`n--- RAW END ---" -f $exit, $tempLog, $rawText)
    }
  }

  # Parse the model's JSON
  return Get-JsonFromText -Text ($raw -is [array] ? ($raw -join "`n") : [string]$raw)
}

# ---------- Use the resolved $cfg ----------
$promptText = Get-Content $tempPrompt -Raw
Write-Host "Resolved CONTINUE_CONFIG slug: '$cfg'"

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
