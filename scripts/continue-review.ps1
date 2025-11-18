<#

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
  [switch]$DebugPayload,
  [switch]$DryRun,
  [int]$SnippetContextLines = 12
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

function Get-PRReviewComments {
  param(
    [string]$Owner,
    [string]$Repo,
    [int]   $PrNumber
  )

  $page = 1
  $all  = @()
  do {
    try {
      $resp = Invoke-GitHub -Path "/repos/$Owner/$Repo/pulls/$PrNumber/comments?per_page=100&page=$page"
    } catch {
      Write-Warning ("Failed to fetch PR review comments (page {0}): {1}" -f $page, $_)
      break
    }

    if ($resp) {
      $all += $resp
      $page++
    } else {
      break
    }
  } while ($resp.Count -eq 100)

  return $all
}


function Get-FileContent {
  param([string]$Owner,[string]$Repo,[string]$Path,[string]$RefSha)
  try {
    # Read from the checked-out workspace only. The action checks out the repo with fetch-depth: 0,
    # so local files should always be available and this avoids API calls and rate limits.
    $repoRoot = $env:GITHUB_WORKSPACE
    if (-not $repoRoot) {
      Write-Warning "GITHUB_WORKSPACE is not set; cannot read local files."
      return $null
    }

    $localPath = Join-Path $repoRoot $Path
    if (-not (Test-Path $localPath)) {
      Write-Warning ("Local file not found: {0}" -f $localPath)
      return $null
    }

    try {
      Write-Host ("Reading file from workspace: {0}" -f $localPath)
      return Get-Content -Path $localPath -Raw -ErrorAction Stop
    } catch {
      Write-Warning ("Failed reading local file {0}: {1}" -f $localPath, $_)
      return $null
    }
  } catch {
    Write-Warning ("Get-FileContent unexpected error for {0}: {1}" -f $Path, $_)
    return $null
  }
}



############################################################################
# Repo / PR discovery
############################################################################
$ErrorActionPreference = 'Stop'

try {
$owner, $repo = $env:GITHUB_REPOSITORY.Split('/')
$evtPath = $env:GITHUB_EVENT_PATH
$evt = Get-Content $evtPath -Raw | ConvertFrom-Json

# When triggered by an issue_comment on a PR, GitHub places the PR link under
# github.event.issue.pull_request, not at github.event.pull_request. Some
# downstream logic (and external actions) expect a top-level pull_request.
# If we have an issue_comment on a PR but no top-level pull_request, fetch the
# PR via the REST API and inject it into the event payload so the rest of the
# script can operate as if this were a pull_request event.
if ($env:GITHUB_EVENT_NAME -eq 'issue_comment' -and $evt.issue -and $evt.issue.pull_request -and -not $evt.pull_request) {
  try {
    $prNumber = $evt.issue.number
    Write-Host "issue_comment on PR #$prNumber detected; fetching PR to synthesize pull_request payload."
    $pr = Get-PR -Owner $owner -Repo $repo -PrNumber $prNumber
    if ($pr) {
      $evt | Add-Member -NotePropertyName 'pull_request' -NotePropertyValue $pr -Force

      try {
        # Overwrite the event file so subsequent steps/actions see the enriched payload
        $evt | ConvertTo-Json -Depth 10 | Set-Content -Path $evtPath -Encoding UTF8
        Write-Host "Injected pull_request payload into event file."
      } catch {
        Write-Warning ("Failed to write enriched event payload to $($evtPath): {0}" -f $_)
      }
    } else {
      Write-Warning "Could not fetch PR #$prNumber to inject into event payload."
    }
  } catch {
    Write-Warning ("Failed to enrich event payload for issue_comment trigger: {0}" -f $_)
  }
}

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

# Build commentable line whitelist (HEAD/right only), and richer numbered snippets
$validLines = @{}
$numberedFiles = @()

foreach ($f in $relevant) {
    $path = $f.path

    # 1) Collect HEAD/RIGHT line numbers from the diff (unchanged behavior)
    $headLineNumbers = @(
        foreach ($chunk in $f.chunks) {
            foreach ($chg in $chunk.changes) {
                if ($chg.ln2) { [int]$chg.ln2 }
            }
        }
    ) | Sort-Object -Unique

    $validLines[$path] = $headLineNumbers

    # 2) Try to build a rich snippet from the HEAD file on disk
    $richLines = @()
    $fileContent = Get-FileContent -Owner $owner -Repo $repo -Path $path -RefSha $headSha

    if ($fileContent -and $headLineNumbers.Count -gt 0) {
        $fileLines = $fileContent -split "`r?`n"

        if ($fileLines.Length -gt 0) {
            # Collect all line numbers to include (changed lines +/- SnippetContextLines)
            $lineIndexes = @()

            foreach ($ln in $headLineNumbers) {
                if ($ln -le 0 -or $ln -gt $fileLines.Length) { continue }

                $start = [Math]::Max(1, $ln - $SnippetContextLines)
                $end   = [Math]::Min($fileLines.Length, $ln + $SnippetContextLines)

                for ($i = $start; $i -le $end; $i++) {
                    $lineIndexes += $i
                }
            }

            # De-duplicate and sort the line numbers
            $lineIndexes = $lineIndexes | Sort-Object -Unique

            foreach ($i in $lineIndexes) {
                $text = $fileLines[$i - 1]
                $richLines += ("{0} {1}" -f $i, $text)
            }
        }
    }

    # 3) Fallback: if for some reason we couldn't read the file,
    #    use the original diff-based snippet (current behavior).
    if (-not $richLines -or $richLines.Count -eq 0) {
        $richLines = foreach ($chunk in $f.chunks) {
            foreach ($chg in $chunk.changes) {
                if ($chg.ln2) { "{0} {1}" -f $chg.ln2, $chg.content }
            }
        }
    }

    $numberedFiles += [pscustomobject]@{
        path = $path
        diff = ($richLines -join "`n")
    }
}

Write-Host ("Prepared {0} relevant changed file(s) for review." -f $numberedFiles.Count)

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

############################################################################
# Build deterministic Business Central object metadata (bcObjects)
############################################################################

$bcObjects = @()

foreach ($f in $relevant) {
  # Only consider AL files
  if (-not $f.path -or -not ($f.path.ToLower().EndsWith('.al'))) {
    continue
  }

  # Fetch HEAD version of the file so metadata matches the current PR state
  $content = Get-FileContent -Owner $owner -Repo $repo -Path $f.path -RefSha $headSha
  if (-not $content) {
    continue
  }

    $lines = $content -split "`r?`n"

    # --- Namespace and using imports ----------------------------------------
  $namespace = $null
  $usings    = @()

  foreach ($ln in $lines) {
    if (-not $namespace -and $ln -match '^\s*namespace\s+(?<ns>.+?);') {
      $rawNs = ([string]$matches['ns']).Trim()
      if (-not $rawNs) { continue }
        if ($rawNs.StartsWith('"') -and $rawNs.EndsWith('"') -and $rawNs.Length -ge 2) {
          $namespace = $rawNs.Substring(1, $rawNs.Length - 2)
        } else {
          $namespace = $rawNs
        }
      }

    if ($ln -match '^\s*using\s+(?<using>.+?);') {
      $rawUsing = ([string]$matches['using']).Trim()
      if (-not $rawUsing) { continue }
        if ($rawUsing.StartsWith('"') -and $rawUsing.EndsWith('"') -and $rawUsing.Length -ge 2) {
          $usings += $rawUsing.Substring(1, $rawUsing.Length - 2)
        } else {
          $usings += $rawUsing
        }
    }
  }


  $headerIndex = -1
  $objType = $null
  $objId = $null
  $objName = $null


  # Best-effort AL object header detection:
  #   page 50100 "My Page"
  #   pageextension 50101 "My Ext" extends "Customer Card"
    for ($i = 0; $i -lt $lines.Length; $i++) {
    $lineText = $lines[$i]
    if ($lineText -match '^\s*(?<objType>\w+)\s+(?<objId>\d+)\s+(?<objName>"[^"]+"|\w+)\b') {
      $headerIndex = $i
      $objType  = ([string]$matches['objType']).Trim()
      $objIdRaw = ([string]$matches['objId']).Trim()

      if ($objIdRaw) {
        [int]$objId = $objIdRaw
      }

      $nameRaw = ([string]$matches['objName']).Trim()
      if (-not $nameRaw) {
        $objName = $null
        break
      }
        if ($nameRaw.StartsWith('"') -and $nameRaw.EndsWith('"') -and $nameRaw.Length -ge 2) {
          $objName = $nameRaw.Substring(1, $nameRaw.Length - 2)
        } else {
          $objName = $nameRaw
        }
      break
    }
  }


  if ($headerIndex -lt 0) { continue }

  # Collect object-level properties until the first structural section (layout/actions/keys/fields/…) 
  $props = @{}
  for ($j = $headerIndex + 1; $j -lt $lines.Length; $j++) {
    $propLine = $lines[$j]

    # Stop once we hit the start of layout/actions/fields/etc. (object sections, not properties)
    if ($propLine -match '^\s*(layout|actions|area\s*\(|group\s*\(|repeater\s*\(|field\s*\(|keys|trigger|var|labels|requestpage|dataset)\b') {
      break
    }

        if ($propLine -match '^\s*(?<propName>\w+)\s*=\s*(?<propValue>.+?);') {
      $pName  = ([string]$matches['propName']).Trim()
      $pValue = ([string]$matches['propValue']).Trim()

      if (-not $pName) { continue }

      if (-not $props.ContainsKey($pName)) {
                switch ($pName) {
          'PageType'           { $props['PageType']           = $pValue }
          'ApplicationArea'    { $props['ApplicationArea']    = $pValue }
          'UsageCategory'      { $props['UsageCategory']      = $pValue }
          'SourceTable'        { $props['SourceTable']        = $pValue }
          'DataClassification' { $props['DataClassification'] = $pValue }
          'Editable'           { $props['Editable']           = $pValue }
          'InsertAllowed'      { $props['InsertAllowed']      = $pValue }
        }
      }
    }

  }

        $bcObjects += [pscustomobject]@{
    path               = $f.path
    objectType         = $objType
    id                 = $objId
    name               = $objName
    namespace          = $namespace
    usings             = $usings
    pageType           = $props['PageType']
    applicationArea    = $props['ApplicationArea']
    usageCategory      = $props['UsageCategory']
    sourceTable        = $props['SourceTable']
    dataClassification = $props['DataClassification']
    editable           = $props['Editable']
    insertAllowed      = $props['InsertAllowed']
    properties         = $props
  }

}

Write-Host ("Discovered {0} changed objects" -f $bcObjects.Count)
if ($DebugPayload -and $bcObjects.Count -gt 0) {
  Write-Host "::group::DEBUG: bcObjects (parsed)"
  try {
    $bcObjects | ConvertTo-Json -Depth 6 | ForEach-Object { Write-Host $_ }
  } catch {
    Write-Warning "Failed to convert bcObjects to JSON for debug: $_"
  }
  Write-Host "::endgroup::"
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

############################################################################
# Load previous PR review comments (for model context)
############################################################################
$existingComments = Get-PRReviewComments -Owner $owner -Repo $repo -PrNumber $prNumber
Write-Host ("Found {0} existing PR review comment(s) on this PR" -f $existingComments.Count)

# Normalize and cap previous comments to keep payload reasonable
$previousComments = @(
  $existingComments |
    Sort-Object created_at |
    Select-Object -First 200 |
    ForEach-Object {
      [pscustomobject]@{
        id         = $_.id
        path       = $_.path
        line       = $_.line
        body       = $_.body
        author     = $_.user.login
        created_at = $_.created_at
      }
    }
)

$hasPreviousComments = $previousComments.Count -gt 0

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
- `bcObjects`: parsed AL object metadata per file (objectType, id, name, PageType, ApplicationArea, UsageCategory, SourceTable, namespace, usings).
- `pullRequest`: title, description, and SHAs.

- `projectContext`: optional extra context from the workflow.
- `previousComments`: earlier PR review comments for context (if any).

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

- Use at most $maxInline comments; prioritize **blockers**, correctness, upgrade risks, and business process impact.
- Don't duplicate earlier comments (previousComments). Don't repeat these inline; if they’re still relevant, mention that in Summary instead.
- comments: [] is valid and recommended when there’s nothing new and high-value.
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
  files          = $numberedFiles
  validLines     = $validLines
  contextFiles   = $ctxFiles
  bcObjects      = $bcObjects
  pullRequest    = @{
    title       = $pr.title
    description = $pr.body
    base        = $pr.base.sha
    head        = $pr.head.sha
  }
  projectContext   = $ProjectContext
  previousComments = $previousComments
}


$tempPrompt = Join-Path $env:RUNNER_TEMP 'continue_prompt.txt'
$tempJson   = Join-Path $env:RUNNER_TEMP 'continue_input.json'
$payload | ConvertTo-Json -Depth 8 | Set-Content -Path $tempJson -Encoding UTF8

if ($DebugPayload) {
  Write-Host "::group::DEBUG: continue_input.json (payload)"
  try {
    $json = $payload | ConvertTo-Json -Depth 8
    # Emit JSON line-by-line so it appears nicely in GitHub Actions logs
    $json -split "`n" | ForEach-Object { Write-Host $_ }
  } catch {
    Write-Warning "Failed to convert payload to JSON for debug: $_"
  }
  Write-Host "::endgroup::"
}

# Build a single prompt text (reviewContract + machine-readable section)
@"
$reviewContract

## DIFF (numbered)
$(( $numberedFiles | ConvertTo-Json -Depth 6 ))

## VALID LINES
$(( $validLines | ConvertTo-Json -Depth 6 ))

## CONTEXT FILES (truncated as needed)
$(( @($ctxFiles | Select-Object -First 30) | ConvertTo-Json -Depth 4  ))

## BC OBJECTS (parsed metadata per AL object)
$(( $bcObjects | ConvertTo-Json -Depth 5 ))

## PREVIOUS COMMENTS (truncated as needed)
$(( $previousComments | ConvertTo-Json -Depth 4 ))
"@ | Set-Content -Path $tempPrompt -Encoding UTF8

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

  # ------------------ Locate review-pr.md ------------------
  $reviewPromptPath = $null

  if ($env:GITHUB_ACTION_PATH) {
    # When running as a composite action on GitHub-hosted runners
    $reviewPromptPath = Join-Path $env:GITHUB_ACTION_PATH '.continue/prompts/review-pr.md'
  } elseif ($env:GITHUB_WORKSPACE) {
    # Fallback: assume .continue lives in the workspace (e.g. local experiments)
    $reviewPromptPath = Join-Path $env:GITHUB_WORKSPACE '.continue/prompts/review-pr.md'
  } else {
    # Last resort: resolve relative to this script location
    $scriptRoot = Split-Path -Parent $PSCommandPath
    $repoRoot   = Split-Path -Parent $scriptRoot
    $reviewPromptPath = Join-Path $repoRoot '.continue/prompts/review-pr.md'
  }

  Write-Host "Resolved review prompt path: $reviewPromptPath"

  if (-not (Test-Path -LiteralPath $reviewPromptPath)) {
    throw "Review prompt file not found at '$reviewPromptPath'"
  }

  Write-Host "Running Continue CLI..."

  # Invoke Continue CLI and stream output to runner while saving to a temp file for parsing
  $tempCnOut = Join-Path $env:RUNNER_TEMP 'continue_cn_out.log'

  & cn --prompt $reviewPromptPath --verbose --config $Config `
       -p (Get-Content -Raw $tempPromptFile) --auto 2>&1 |
    Tee-Object -FilePath $tempCnOut

  $exit = $LASTEXITCODE
  $stdout = if (Test-Path $tempCnOut) { Get-Content -Raw $tempCnOut } else { "" }

  if ($exit -ne 0) {
    throw ("Continue CLI failed (exit {0})." -f $exit)
  }

  # Parse the CLI JSON output produced by the model run
  $parsed = Get-JsonFromText -Text $stdout

  # Happy-path heuristic:
  # If cn returns an array like ["{", "  \"summary\": ...", "}", { actualObject }, ...],
  # pick the last object-shaped element that looks like a review.
  if ($parsed -is [System.Collections.IEnumerable] -and -not ($parsed -is [string])) {
    $candidates = @($parsed) | Where-Object {
      $_ -isnot [string] -and
      $_.PSObject.Properties.Name -contains 'summary' -and
      $_.PSObject.Properties.Name -contains 'comments'
    }

    if ($candidates.Count -gt 0) {
      return $candidates[-1]
    }
  }

  return $parsed
}

# ---------- Execute ----------
$promptText = Get-Content $tempPrompt -Raw
Write-Host "Resolved Continue config file: '$cfg'"
try {
  $review = Invoke-ContinueCli -Config $cfg -Prompt $promptText

  # Continue CLI sometimes returns a small list, e.g.
  #   [ "<raw JSON as string>", { summary = "..."; comments = [...] } ]
  # For our GitHub integration we only want the actual review object.
  if ($review -is [System.Collections.IEnumerable] -and -not ($review -is [string])) {
      $nonString = $review | Where-Object { $_ -isnot [string] }
      if ($nonString -and $nonString.Count -gt 0) {
          $review = $nonString[-1]   # take the last real object as the canonical review
      }
  }
} catch {
  throw "Continue run failed: $($_.Exception.Message)"
}


############################################################################
# Normalize and validate model output
############################################################################
if (-not $review) {
  throw "Continue CLI returned no review payload."
}

if ($DebugPayload) {
  Write-Host "::group::DEBUG: raw review from Continue"
  try {
    $review | ConvertTo-Json -Depth 8 | ForEach-Object { Write-Host $_ }
  } catch {
    Write-Warning "Failed to convert raw review to JSON for debug: $_"
  }
  Write-Host "::endgroup::"
}

# Normalize suggestedAction
$validSuggested = @('approve','request_changes','comment')
if (
  -not ($review.PSObject.Properties.Name -contains 'suggestedAction') -or
  -not $review.suggestedAction -or
  -not ($validSuggested -contains ($review.suggestedAction.ToString().ToLower()))
) {
  $review | Add-Member -NotePropertyName suggestedAction -NotePropertyValue 'comment' -Force
}

# Normalize comments into a predictable array shape (happy path)
$rawComments = @($review.comments)

$normalizedComments = $rawComments | Where-Object {
    $_ -and $_.path -and $_.line -and $_.remark
}

$review | Add-Member -NotePropertyName comments -NotePropertyValue $normalizedComments -Force

Write-Host ("Model returned {0} comment(s); using {1} after normalization." -f `
    $rawComments.Count, $normalizedComments.Count)

############################################################################

# Dry-run: show the result and skip all GitHub write operations
if ($DryRun) {
  Write-Host "::group::DRY RUN: review result (no GitHub calls)"
  try {
    $out = [pscustomobject]@{
      summary         = $review.summary
      suggestedAction = $review.suggestedAction
      comments        = $review.comments
    }
    $out | ConvertTo-Json -Depth 6 | ForEach-Object { Write-Host $_ }
  } catch {
    Write-Warning "Failed to dump dry-run review JSON: $_"
  }
  Write-Host "::endgroup::"
  return
}

############################################################################
# Post summary as a safe, standalone review first
############################################################################

$event = 'COMMENT'
if ($ApproveReviews) {
  switch ($review.suggestedAction) {
    'approve'         { $event = 'APPROVE' }
    'request_changes' { $event = 'REQUEST_CHANGES' }
    default           { $event = 'COMMENT' }
  }
}

# Simple observability of what the model decided
$suggestedActionValue = 'null'
if ($review.PSObject.Properties.Name -contains 'suggestedAction' -and $review.suggestedAction) {
  $suggestedActionValue = [string]$review.suggestedAction
}
Write-Host ("Continue suggestedAction: {0} -> GitHub review event: {1}" -f `
  $suggestedActionValue, $event)

# Footer to credit engine/config (non-blocking)
$footer = "`n`n---`n_Review powered by [Continue CLI](https://continue.dev) and [bc-ai-reviewer](https://github.com/AidentErfurt/bc-ai-reviewer)_."
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
    Write-Host ("MaxComments limit {0} hit; truncating from {1} to {0} comment(s)." -f `
    $MaxComments, $comments.Count)
  $comments = $comments[0..($MaxComments - 1)]
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
      # Optional: strip any rogue ``` the model might sneak in, just in case
      $cleanSuggestion = ($suggestion -replace '```', '').TrimEnd()

      $bodyFinal += "`n`n" +
                    '```suggestion' + "`n" +
                    $cleanSuggestion + "`n" +
                    '```'
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
} catch {
  Write-Error ("Fatal error in continue-review.ps1: {0}" -f $_.Exception.Message)
  Write-Error $_.Exception.ToString()
  exit 1
}
