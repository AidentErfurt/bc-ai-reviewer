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
  [string]$IncludePatterns = "**/*.al",
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

# Filter by include/exclude globs (verbose diagnostics)
if (-not $IncludePatterns -or $IncludePatterns.Trim().Length -eq 0) { $IncludePatterns = "**/*.al" }

# Split and normalize include/exclude tokens (extensions -> globs)
$inc = $IncludePatterns -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
$exc = $ExcludePatterns -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
$inc = $inc | ForEach-Object {
  if ($_ -match '[\*\/\\]') { $_ } elseif ($_ -match '^\.') { "**/*$$_" } else { "**/*.$_" }
}

$compiledIncludes = $inc | ForEach-Object { [System.Management.Automation.WildcardPattern]::Get($_, [System.Management.Automation.WildcardOptions]::IgnoreCase) }
$compiledExcludes = $exc | ForEach-Object { [System.Management.Automation.WildcardPattern]::Get($_, [System.Management.Automation.WildcardOptions]::IgnoreCase) }

Write-Host "Normalized include patterns: $($inc -join ', ')"
Write-Host "Exclude patterns: $($exc -join ', ')"

Write-Host "Changed files from parse-diff:"
foreach ($f in $files) {
  $pOut = ($f.path -replace '\\','/').TrimStart('./')
  Write-Host " - $pOut"
}

$relevant = @()
foreach ($f in $files) {
  $p = ($f.path -replace '\\','/').TrimStart('./')
  $matchedInclude = $false
  foreach ($pat in $compiledIncludes) { if ($pat.IsMatch($p)) { $matchedInclude = $true; break } }
  $matchedExclude = $false
  foreach ($epat in $compiledExcludes) { if ($epat.IsMatch($p)) { $matchedExclude = $true; break } }

  if ($matchedInclude -and -not $matchedExclude) {
    $relevant += $f
  } else {
    Write-Host "Skipping $p (include=$matchedInclude exclude=$matchedExclude)"
  }
}

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
You are a **senior Dynamics 365 Business Central AL architect and code reviewer**.

Your goals:

- Produce a **Business Central-aware, professional PR review** that:
  - Follows ALGuidelines.dev (AL Guidelines / Vibe Coding Rules) and official AL analyzers (CodeCop, PerTenantExtensionCop, AppSourceCop, UICop).
  - Evaluates both **code quality** and **business process impact** (posting, journals, VAT, dimensions, approvals, inventory, pricing, etc.).
  - Provides **short, actionable inline comments** plus a single, high-quality markdown review.

You will be given (in the prompt body):

- `files`: changed files with **numbered diffs**.
- `validLines`: whitelisted commentable **HEAD/RIGHT line numbers** per file.
- `contextFiles`: additional files (e.g. `app.json`, permission sets, markdown docs) for reasoning only.
- `pullRequest`: title, description, and SHAs.
- `projectContext`: optional extra context from the workflow.

Return **only this JSON object** (no markdown fences, no extra text):

{
  "summary": "Full markdown review for the PR, using the headings: '### Summary', '### Major Issues (blockers)', '### Minor Issues / Nits', '### Tests', '### Security & Privacy', '### Performance', '### Suggested Patches', '### Changelog / Migration Notes', '### Verdict'. Each section must follow the Business Central AL review template and explicitly mention risk level and business process impact where relevant.",
  "comments": [
    {
      "path": "path/in/repo.al",
      "line": 123,
      "remark": "1-3 paragraph GitHub review comment. Focus on one issue and explain the impact in Business Central terms.",
      "suggestion": "Optional AL replacement snippet (≤6 lines) with no backticks and no 'suggestion' label. Leave empty string if no suggestion."
    }
  ],
  "suggestedAction": "approve | request_changes | comment",
  "confidence": 0.0
}

Requirements for `summary`:

- It is the **primary review output** and should stand alone as a professional review.
- Use the headings exactly:
  - `### Summary`
  - `### Major Issues (blockers)`
  - `### Minor Issues / Nits`
  - `### Tests`
  - `### Security & Privacy`
  - `### Performance`
  - `### Suggested Patches`
  - `### Changelog / Migration Notes`
  - `### Verdict`
- Under **Summary**, briefly describe:
  - Scope of the change.
  - Technical impact (key objects / areas).
  - Business process impact (e.g. posting flows, approvals, inventory, VAT, pricing, integrations).
  - Overall risk level: Low / Medium / High (with a short justification).
- Under each section, prioritize Business Central-specific concerns:
  - Correctness in posting/ledger logic, dimensions, VAT, currencies, approvals.
  - Upgrade safety and schema changes.
  - Performance of posting, batch, reports, and integrations.
  - Security/permissions and data classification.
- Do **not** include raw JSON or the `validLines`/`files` structures in the markdown.

Requirements for `comments`:

- Use at most $maxInline comments; prioritize **blockers**, correctness, upgrade risks, and large business impact.
- Each comment object has:
  - `path`: file path from the diff. Must match a file present in `files`.
  - `line`: a line number taken only from `validLines[path]` (these are HEAD/RIGHT line numbers from the diff).
  - `remark`: the natural-language feedback (≤ 3 short paragraphs). Be direct and respectful.
  - `suggestion`: optional AL replacement snippet (≤ 6 lines). **No backticks**, no `suggestion` label; the caller will wrap it in the correct GitHub ```suggestion``` block.
- If there is no safe, minimal replacement, set `suggestion` to an empty string.


Additional constraints:

- Do not reference `contextFiles` by path or filename in comments; they are for your reasoning only.
- When you are unsure about business impact, say so explicitly in the **Summary** and state your assumption (e.g., “Assuming this codeunit is only used for internal tools…”).
- If there are more potential comments than the allowed limit, aggregate the extra feedback into the `summary` under the appropriate headings.
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

  Write-Host "::group::Continue CLI environment"
  try { $cnVer = (& cn --version) 2>&1 } catch { throw "Continue CLI (cn) not found on PATH." }
  Write-Host "cn --version:`n$cnVer"
  Write-Host "CONTINUE_CONFIG (file): $Config"
  Write-Host "::endgroup::"

  # Write prompt to a temp file
  $tempPromptFile = Join-Path $env:RUNNER_TEMP 'continue_prompt.txt'
  $Prompt | Set-Content -Path $tempPromptFile -Encoding UTF8

  Write-Host "Running Continue CLI..."

  # Invoke Continue CLI and stream output to runner while saving to a temp file for parsing
  $tempCnOut = Join-Path $env:RUNNER_TEMP 'continue_cn_out.log'
  # Use Tee-Object so cn's output is both printed to the runner log and written to a file
  & cn --config $Config -p (Get-Content -Raw $tempPromptFile) --auto 2>&1 | Tee-Object -FilePath $tempCnOut
  $exit = $LASTEXITCODE
  $stdout = if (Test-Path $tempCnOut) { Get-Content -Raw $tempCnOut } else { "" }

  if ($exit -ne 0) {
    throw ("Continue CLI failed (exit {0})." -f $exit)
  }

  # Parse the CLI JSON output produced by the model run and return it
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
$footer = "`n`n---`n_Review powered by [Continue CLI](https://continue.dev) and [bc-ai-reviewer](https://github.com/AidentErfurt/bc-ai-reviewer). Config: **$cfg**_"
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
  $remark = [string]$c.remark
  $suggestion = [string]$c.suggestion

  if (-not $path -or -not $remark) { continue }

  $whitelist = $validLines[$path]
  $sideFor   = $sideMap[$path]

  # Build GitHub comment body: remark + optional suggestion block
  $bodyFinal = $remark.TrimEnd()
  if ($suggestion -and $suggestion.Trim()) {
    $bodyFinal += "`n`n```suggestion`n" + $suggestion.TrimEnd() + "`n````"
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
