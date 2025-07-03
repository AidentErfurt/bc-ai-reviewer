<#
Copyright 2025 Aident GmbH

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
#>

<#
.SYNOPSIS
    Run an AI-powered code review on a GitHub pull request using OpenAI or Azure OpenAI.

.DESCRIPTION
    Connects to GitHub REST & GraphQL APIs to fetch PR diffs, context files, and linked issues;
    invokes OpenAI/Azure for an AI review; then posts comments or approves the PR.

.PARAMETER GitHubToken
    Personal Access Token with repo scope.

.PARAMETER Provider
    AI provider: 'openai' or 'azure'. Default 'openai'.

.PARAMETER Model
    Deployment or model name. Default 'gpt-4o-mini'.

.PARAMETER ApiKey
    OPENAI_API_KEY (required when Provider is 'openai').

.PARAMETER AzureEndpoint
    Azure OpenAI endpoint URL (required when Provider is 'azure').

.PARAMETER AzureApiKey
    Azure OpenAI API key (required when Provider is 'azure').

.PARAMETER AzureApiVersion
    Azure OpenAI API version. Default '2024-05-01-preview'.

.PARAMETER ApproveReviews
    Switch. Approve or request changes instead of only commenting.

.PARAMETER MaxComments
    Maximum inline comments to post (0 = unlimited). Default 0.

.PARAMETER ProjectContext
    Free-form architecture or guidelines.

.PARAMETER ContextFiles
    Comma-separated list of file globs to always fetch. Default 'README.md'.

.PARAMETER IncludePatterns
    Comma-separated glob patterns of files to include in diff. Default '**/*.al,**/*.xlf,**/*.json'.

.PARAMETER ExcludePatterns
    Comma-separated glob patterns to exclude. Default ''.

.PARAMETER IssueCount
    Max number of linked issues to fetch (0 = all). Default 0.

.PARAMETER FetchClosedIssues
    Switch. Include closed issues in context.

.PARAMETER OpenRouterReferer
    Optional OpenRouter marketing headers.

.PARAMETER OpenRouterTitle
    Optional OpenRouter marketing headers.

.PARAMETER DiffContextLines
    Control the number of lines that surround each difference when running git diff.

.PARAMETER AutoDetectApps
    Auto-include app.json files as context.

.PARAMETER IncludeAppPermissions
     Auto-include permissionsets and entitlements as context. Only honoured if AutoDetectApps is on.

.PARAMETER IncludeAppMarkdown
    Auto-include markdown files as context. Only honoured if AutoDetectApps is on.

.PARAMETER BasePromptExtra
    Free-form text injected into the system prompt.

.PARAMETER GuidelineRulesPath
    Optional path to a JSON or PSD1 file defining custom AL‐Guideline rules.

.PARAMETER DisableGuidelineDocs
    Switch. Skip fetching AL-Guidelines docs.

.EXAMPLE
    .\main.ps1 -GitHubToken $env:GITHUB_TOKEN -Provider azure -AzureEndpoint 'https://...' -ContextFiles 'README.md,docs/*.md'

.INPUTS
    None. All parameters.

.OUTPUTS
    None.
#>
function Invoke-AICodeReview {
    [CmdletBinding(DefaultParameterSetName = 'Azure')]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$GitHubToken,

        [ValidateSet('openai','azure','openrouter')]
        [string]$Provider = 'openai',

        [string]$Model       = 'o3-mini',

        # --- OpenAI / OpenRouter (public) ----------------------------------------------------
        [Parameter(ParameterSetName='OpenAI', Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ApiKey,
        [string]$OpenRouterReferer,
        [string]$OpenRouterTitle,

        # --- Azure OpenAI -------------------------------------------------------
        [Parameter(ParameterSetName='Azure', Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$AzureEndpoint,

        [Parameter(ParameterSetName='Azure', Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$AzureApiKey,

        [string]$AzureApiVersion = '2024-05-01-preview',

        # -----------------------------------------------------------------------
        [switch]$ApproveReviews,
        [ValidateRange(0,[int]::MaxValue)]
        [int]$MaxComments = 10,

        [string]$ProjectContext = '',
        [string]$ContextFiles    = '',
        [string]$IncludePatterns = '**/*.al,**/*.xlf,**/*.json',
        [string]$ExcludePatterns = '',

        [ValidateRange(0,[int]::MaxValue)]
        [int]$IssueCount = 0,
        [switch] $FetchClosedIssues,
        [int] $DiffContextLines = 5,
        [bool] $AutoDetectApps        = $false,
        [bool] $IncludeAppPermissions = $true,
        [bool] $IncludeAppMarkdown    = $true,
        [string] $BasePromptExtra,
        [string] $GuidelineRulesPath = '',
        [switch] $DisableGuidelineDocs
    )

Begin {

    Set-StrictMode -Version Latest

    ############################################################################
    # Helpers
    ############################################################################
    ############################################################################
    # Helper: Call OpenAI / Azure OpenAI / OpenRouter
    ############################################################################
    
    function Invoke-OpenAIChat {
        param([array]$Messages)
        if ($Provider -eq 'azure') {
            $uri = "$AzureEndpoint/openai/deployments/$Model/chat/completions?api-version=$AzureApiVersion"
            $hdr = @{ 'api-key' = $AzureApiKey; 'Content-Type' = 'application/json' }
        } 
        elseif ($Provider -eq 'openrouter') {
            $uri = 'https://openrouter.ai/api/v1/chat/completions'   # OpenRouter base URL :contentReference[oaicite:0]{index=0}
            $hdr = @{ Authorization = "Bearer $ApiKey"; 'Content-Type' = 'application/json' }
            if ($OpenRouterReferer) { $hdr.'HTTP-Referer' = $OpenRouterReferer }
            if ($OpenRouterTitle)   { $hdr.'X-Title'      = $OpenRouterTitle }
        }
        else {
            $uri = 'https://api.openai.com/v1/chat/completions'
            $hdr = @{ Authorization = "Bearer $ApiKey"; 'Content-Type' = 'application/json' }
        }
        $body = @{
            messages   = $Messages
            model      = $Model
        }
        #TODO
        # temperature = 0.2
        # top_p       = 0.8
        # max_tokens  = 1024   # hard guardrail

        # azure zure passes the model via the url
        if ($Provider -in @('openai','openrouter')) { 
            $body.model = $Model 
        }

        Write-Host "Provider: $Provider"
        Write-Host "Endpoint: $uri"
        Write-Host "Model:    $Model"
        Write-Host ""

        try {
            Invoke-RestMethod -Method POST -Uri $uri -Headers $hdr -Body ($body | ConvertTo-Json -Depth 5)
        } catch {
            Write-Error "OpenAI call failed: $_"
            throw
        }
    }

    ############################################################################
    # Helper: GitHub REST & GraphQL calls
    ############################################################################

    function Invoke-GitHub {
        param(
            [string]$Method = 'GET',
            [string]$Path,
            [object]$Body   = $null,
            [string]$Accept = 'application/vnd.github+json'
        )
        $uri = "https://api.github.com$Path"
        $hdr = @{
            Authorization          = "Bearer $GitHubToken"
            Accept                 = $Accept
            'X-GitHub-Api-Version' = '2022-11-28'
            'User-Agent'           = 'ai-codereviewer-pwsh'
        }
        if ($Body) { $Body = $Body | ConvertTo-Json -Depth 100 }
        try {
            Invoke-RestMethod -Method $Method -Uri $uri -Headers $hdr -Body $Body
        } catch {
            Write-Error "GitHub API call failed ($Method $Path): $_"
            throw
        }
    }

    ############################################################################
    # helper: return every issue linked to the PR (GraphQL)
    ############################################################################

    function Get-PRLinkedIssues {
        param($Owner, $Repo, [int]$PrNumber)

        # -- GraphQL ------------------------------------------------------------
$query = @'
query ($owner:String!, $repo:String!, $pr:Int!) {
repository(owner:$owner, name:$repo) {
pullRequest(number:$pr) {
body
closingIssuesReferences(first: 50) {
    nodes { number }         # issues closed by “Fixes/Closes #123”
}
}
}
}
'@

        $body = @{
            query     = $query
            variables = @{ owner = $Owner; repo = $Repo; pr = $PrNumber }
        }

        $resp = Invoke-GitHub -Method POST -Path '/graphql' -Body $body

        if ($resp.PSObject.Properties['errors']) {
            Write-Warning ("GraphQL returned {0} error(s):`n{1}" -f `
                $resp.errors.Count, ($resp.errors | ConvertTo-Json -Depth 5))
        }
        if (-not $resp.data) { return @() }

        $prNode   = $resp.data.repository.pullRequest
        $closing  = @($prNode.closingIssuesReferences.nodes | ForEach-Object number)

        # fallback: plain “#123” mentions in the PR body 
        $mentioned = ([regex]'#(?<n>\d+)\b').Matches($prNode.body) |
                    ForEach-Object { [int]$_.Groups['n'].Value }

        # merge + dedupe + sort
        return ($closing + $mentioned | Select-Object -Unique | Sort-Object)
    }

    ########################################################################
    # helper: normalise a git patch for guideline scanning
    ########################################################################
    
    function Convert-PatchToCode {
        <#
            .SYNOPSIS
                Convert a unified diff into plain AL code, keeping a mapping
                CleanCodeLineNo -> UnifiedDiffLineNo  (Hashtable[int,int])

            .OUTPUTS
                [pscustomobject] @{ Text = <string>; Map = <hashtable> }
        #>
        param([string]$Patch)

        $code   = [System.Text.StringBuilder]::new()
        $map    = @{}          # clean-line-no  ->  diff-line-no
        $cleanL = 0
        $diffL  = 0

        foreach ($raw in $Patch -split "`n") {
            $line = ''
            $diffL++

            if ($raw -match '^(diff --git|index |--- |\+\+\+ |@@ )') {
                continue  # skip diff metadata
            }

            if ($raw.Length -eq 0) { continue }

            switch ($raw[0]) {
                '-' { continue }                     # pure deletion -> ignore        }
                '+' { $line = $raw.Substring(1) }    # addition       -> keep w/o '+'
                ' ' { $line = $raw.Substring(1) }    # context        -> keep
                default { continue }                 # anything else  -> ignore
            }

            $cleanL++
            $null = $code.AppendLine($line)
            $map[$cleanL] = $diffL
        }

        [pscustomobject]@{
            Text = $code.ToString()
            Map  = $map
        }
    }

    ############################################################################
    # Helper: alguidelines load rules & fetch functions
    ############################################################################

    function Get-TriggeredGuidelines {
        <#
            .SYNOPSIS
                Return every guideline hit plus:
                - the first matching snippet (≤120 chars)
                - the 1-based line number inside the unified diff

            .OUTPUTS
                [pscustomobject] Rule, Snippet, Line
        #>
        param(
            [string]     $Patch,
            [hashtable]  $Rules   = $DefaultGuidelineRules,
            [int]        $MaxLen  = 120
        )

        $hits = @()

        foreach ($kvp in $Rules.GetEnumerator()) {
            $ruleName = $kvp.Key
            foreach ($rx in @($kvp.Value.patterns)) {
                $m = [regex]::Match($Patch, $rx, 'IgnoreCase,Multiline')
                if ($m.Success) {
                    # Calculate line number (= 1 + count of LF before the match)
                    $line = ([regex]::Matches($Patch.Substring(0, $m.Index), "`n")).Count + 1

                    $snippet = $m.Value.Replace("`r",' ').Replace("`n",' ')
                    if ($snippet.Length -gt $MaxLen) { $snippet = $snippet.Substring(0,$MaxLen) + '…' }

                    $hits += [pscustomobject]@{
                        Rule    = $ruleName
                        Snippet = $snippet
                        Line    = $line
                    }
                    break    # stop after first pattern for this rule
                }
            }
        }
        return $hits
    }

    function Get-GuidelineDoc {
        param([string]$RuleName,[string]$Folder)
        $cache = "$env:RUNNER_TEMP\alguideline-cache"
        if (-not (Test-Path $cache)) { New-Item $cache -ItemType Directory -Force | Out-Null }
        $file = Join-Path $cache "$RuleName.md"
        if (-not (Test-Path $file)) {
            $url = "https://raw.githubusercontent.com/microsoft/alguidelines/main/content/docs/BestPractices/$Folder/index.md"
            try {
                $md = Invoke-RestMethod -Uri $url -Headers @{ 'Accept'='text/plain'; 'User-Agent'='al-reviewer' }
                # strip YAML front-matter
                $md = $md -replace '(?s)^---.*?---\s*'
                $md | Set-Content $file -Encoding UTF8
            }
            catch {
                Write-Warning "Could not fetch guideline '$RuleName' ($url): $_"
                return $null
            }
        }
        Get-Content $file -Raw
    }

    ###########################################################################
    # Helper: Autodetect app context
    ###########################################################################

    function Get-NearestAppJson {
        param([string]$Path, [string[]]$AllApps)      # AllApps = resolved app.json paths
        # walk up the directory tree until we hit repo root
        $dir = Split-Path $Path -Parent
        while ($dir) {
            $app = $AllApps | Where-Object { $_ -eq (Join-Path $dir 'app.json') }
            if ($app) { return $app }                 # first hit wins (closest to root)
            $parent = Split-Path $dir -Parent
            if ($parent -eq $dir) { break }           # reached FS root
            $dir = $parent
        }
        return $null
    }
    
    #########################################################
    # Helper: to create the *summary* review only
    #########################################################
    
    function New-Review {
        # guardrail for huge summaries
        if ($review.summary.Length -gt 65000) {
            $review.summary = $review.summary.Substring(0,65000) + "`n…(truncated)"
        }
        $body = @{
        commit_id = $pr.head.sha
        body      = $review.summary
        event     = if ($ApproveReviews) { $review.suggestedAction.ToUpper() } else { 'COMMENT' }
        comments  = $inline             # ← array you already built
        }
        Invoke-GitHub -Method POST -Path "/repos/$owner/$repo/pulls/$prNumber/reviews" -Body $body
    }

    #######################################################################
    # Helper: turns the raw model string into a PowerShell object #
    #######################################################################
    function Convert-FromAiJson {
        param(
            [Parameter(Mandatory)][string]$Raw,
            [int]$MaxAttempts = 5
        )

        $json = $Raw

        for ($try = 1; $try -le $MaxAttempts; $try++) {
            try { return $json | ConvertFrom-Json }
            catch {
                if ($_.Exception.Message -notmatch 'Bad JSON escape sequence: \\(.)') { throw }

                # Grab the offending character the parser complains about
                $badChar = $Matches[1]

                # Back-slash not already doubled AND not followed by ["\/bfnrtu]
                $pat = '(?<!\\)\\(?![\\/"bfnrtu])'
                $json = [regex]::Replace($json, $pat, '\\$&')

                Write-Verbose ("Retry #{0} - escaped `\{1}``" -f $try, $badChar)
            }
        }

        throw "Failed to sanitise AI response after $MaxAttempts attempts."
    }

    ############################################################################
    # Helper: Parse a unified diff into file objects for review
    ############################################################################
    function Parse-Patch {
        param([string]$Patch)

        $files   = @()
        $current = $null
        $leftLn  = 0
        $rightLn = 0

        foreach ($line in $Patch -split "`n") {

            # --- diff header → start new file -----------------------------------
            if ($line -match '^diff --git a\/.+ b\/(?<path>.+)$') {
                if ($current) { $files += $current }
                $current = @{
                    path     = $Matches.path
                    diff     = @()
                    leftMap  = @{}   # old-file   L# → diff index
                    rightMap = @{}   # new-file   L# → diff index
                    diffLines = @()
                }
                $leftLn  = 0
                $rightLn = 0
                continue
            }

            if (-not $current) { continue }

            $current.diff += $line
            $current.diffLines += $line

            # --- hunk header -----------------------------------------------------
            if ($line -match '^@@ -(?<l>\d+)(?:,\d+)? \+(?<r>\d+)(?:,\d+)? @@') {
                $leftLn  = [int]$Matches.l
                $rightLn = [int]$Matches.r
                continue
            }

            if ($line.Length -eq 0) { continue }

            switch ($line[0]) {
                '-' {                     # deletion → only LEFT moves
                    $current.leftMap[$leftLn] = $current.diff.Count
                    $leftLn++
                }
                '+' {                     # addition → only RIGHT moves
                    $current.rightMap[$rightLn] = $current.diff.Count
                    $rightLn++
                }
                ' ' {                     # context → both sides move
                    $current.leftMap[$leftLn]  = $current.diff.Count
                    $current.rightMap[$rightLn] = $current.diff.Count
                    $leftLn++; $rightLn++
                }
            }
        }

        if ($current) { $files += $current }

        # emit objects
        $files | ForEach-Object {
            [pscustomobject]@{
                path     = $_.path
                diff = '```diff' + "`n" + ($_.diff -join "`n") + "`n````"
                leftMap  = $_.leftMap
                rightMap = $_.rightMap
                diffLines = $_.diff
            }
        }
    }

    #########################################################
    # Helper to add a single inline comment to the review
    #########################################################
    
    function Add-ReviewComment {
    param(
        [string]   $ReviewId,   # id returned by New-Review
        [hashtable]$Comment     # @{ path; line; side; body }
    )
    Invoke-GitHub -Method POST `
        -Path "/repos/$owner/$repo/pulls/$prNumber/reviews/$ReviewId/comments" `
        -Body @{
            body      = $Comment.body
            commit_id = $pr.head.sha         # head-commit SHA
            path      = $Comment.path
            side      = $Comment.side        # 'RIGHT' or 'LEFT'
            line      = $Comment.line        # file-relative line no on that side
        }
    }

    ############################################################################
    # Begin block: parameter validation, splitting globs, strict mode…
    ############################################################################

    $ErrorActionPreference = 'Stop'
    Write-Host "Repository: $env:GITHUB_REPOSITORY  Provider: $Provider"

    if ($ApiKey)      { Write-Host "::add-mask::$ApiKey" }
    if ($AzureApiKey) { Write-Host "::add-mask::$AzureApiKey" }

    # Runtime-guard in case empty strings were passed
    if ($Provider -in @('openai','openrouter') -and [string]::IsNullOrWhiteSpace($ApiKey)) {
        throw 'ApiKey is required when -Provider openai | openrouter'
    }
    if ($Provider -eq 'azure' -and
        ([string]::IsNullOrWhiteSpace($AzureEndpoint) -or [string]::IsNullOrWhiteSpace($AzureApiKey))) {
        throw 'AzureEndpoint and AzureApiKey are required when -Provider azure'
    }

    # Split comma-separated inputs into arrays
    $ctxGlobs     = $ContextFiles    -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    $includeGlobs = $IncludePatterns -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    $excludeGlobs = $ExcludePatterns -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }

    }

Process {

    ############################################################################
    # 1. Fetch PR & repository information
    ############################################################################
    $owner, $repo = $env:GITHUB_REPOSITORY.Split('/')
    $evt        = Get-Content $env:GITHUB_EVENT_PATH -Raw | ConvertFrom-Json
    # error‐handle missing pull_request (e.g. manual dispatch or push)
    if (-not $evt.pull_request) {
       Write-Warning "No pull_request payload found (event type: $($env:GITHUB_EVENT_NAME)). Skipping AI code review."
       return
    }
    $prNumber     = $evt.pull_request.number
    Write-Host "Reviewing PR #$prNumber in $owner/$repo"

    $pr = Invoke-GitHub -Path "/repos/$owner/$repo/pulls/$prNumber"

    ############################################################################
    # 2. Determine last reviewed commit (if any)
    ############################################################################
    $reviews = Invoke-GitHub -Path "/repos/$owner/$repo/pulls/$prNumber/reviews"
    $lastBot = $reviews |
        Where-Object { $_.user.login -eq 'github-actions[bot]' } |
        Sort-Object submitted_at -Descending |
        Select-Object -First 1

    $lastCommit = $null
    if ($lastBot) {
        $commits  = Invoke-GitHub -Path "/repos/$owner/$repo/pulls/$prNumber/commits"
        $revDate  = [datetime]$lastBot.submitted_at
        $lastCommit = ($commits |
            Where-Object { [datetime]$_.commit.committer.date -le $revDate } |
            Select-Object -Last 1).sha
    }

    ############################################################################
    # 3. Fetch & parse diff   (incremental)
    ############################################################################
    # decide which commits to diff
    $baseRef = if ($lastCommit) { $lastCommit } else { $pr.base.sha }
    $headRef = $pr.head.sha

    # run git diff with <DiffContextLines> lines of context
    Write-Host "Generating diff with $DiffContextLines lines of context..."
    $patch = (& git diff --unified=$DiffContextLines --find-renames --diff-filter=ACDMR --no-color $baseRef $headRef | Out-String)

    # Guard-rail: abort if the diff is ridiculously large
    $byteSize = [System.Text.Encoding]::UTF8.GetByteCount($patch)
    $maxBytes = 500KB      # tweak here if needed
    if ($byteSize -gt $maxBytes) {
        throw ("The generated diff is {0:N0} bytes (> {1:N0}). " +
            "Consider tightening INCLUDE_PATTERNS / EXCLUDE_PATTERNS " +
            "or splitting the PR." -f $byteSize, $maxBytes)
    }

    # feed the *same* patch the model will see into Parse-Patch
    $files = Parse-Patch $patch

    Write-Host '::group::Files in patch'
    $files.path | ForEach-Object { Write-Host $_ }
    Write-Host '::endgroup::'

    ############################################################################
    # 4. Filter files by include/exclude patterns
    ############################################################################

    # Pre-compile your globs into real WildcardPattern objects:
    $compiledIncludes = $includeGlobs |
        ForEach-Object {
            [System.Management.Automation.WildcardPattern]::Get(
                $_,
                [System.Management.Automation.WildcardOptions]::IgnoreCase
            )
        }

    $compiledExcludes = $excludeGlobs |
        ForEach-Object {
            [System.Management.Automation.WildcardPattern]::Get(
                $_,
                [System.Management.Automation.WildcardOptions]::IgnoreCase
            )
        }

    # Now select only those files that match ≥1 include-pattern and 0 exclude-patterns:
    $relevant = @(
        $files | Where-Object {
        $path = $_.path

        # at least one include-pattern matches?
        (@($compiledIncludes | Where-Object { $_.IsMatch($path) })).Count -gt 0 -and        
        # no exclude-pattern matches?
        (@($compiledExcludes | Where-Object { $_.IsMatch($path) })).Count -eq 0
        }
    )

    if (-not $relevant) {
        Write-Host 'No relevant files to review'
        return
    }

    # Cap to avoid GitHub’s 1000 inline-comment limit
    $maxFiles = 300
    if ($relevant.Count -gt $maxFiles) {
        Write-Warning (
            "Limiting review to first {0} of {1} changed files (GitHub caps inline comments at 1000)." `
            -f $maxFiles, $relevant.Count
        )
        $relevant = $relevant[0..($maxFiles - 1)]
    }

    ###########################################################################
    # 5. Autodetect app context
    ###########################################################################

    $ctxFiles = @()
    if ($AutoDetectApps) {
        # 1) figure out where the checked-out repo lives
        $repoRoot    = $Env:GITHUB_WORKSPACE
        if (-not (Test-Path $repoRoot)) {
            throw "Cannot find GITHUB_WORKSPACE at '$repoRoot'"
        }

        # 2) enumerate all app.json in the repo
        Write-Host '::group::Detect app structure & context'
        $allAppJsons = Get-ChildItem -Path $repoRoot -Recurse -Filter 'app.json' |
                    ForEach-Object { $_.FullName.Replace('\','/') }
        Write-Host "Autodetect app structure. Relevant files = $($relevant.Count). Total apps = $($allAppJsons.Count)"

        # 3) work out which apps are touched by the diff
        $relevantApps = @{}
        foreach ($file in $relevant) {
            $fullPath = Join-Path $repoRoot $file.path
            Write-Host "Checking file for app.json: $($file.path)"
            $appJson = Get-NearestAppJson -Path $fullPath -AllApps $allAppJsons
            if ($appJson) {
                Write-Host "-> Found app.json at $appJson"
                $relevantApps[$appJson] = $true
            } else {
                Write-Host "-> No app.json found for this file"
            }
        }
        Write-Host '::endgroup::'

        # 4) now queue context files for each app.json we care about
        foreach ($appJson in $relevantApps.Keys) {
            $appRoot    = Split-Path $appJson -Parent
            $relAppJson = [IO.Path]::GetRelativePath($repoRoot, $appJson) -replace '\\','/'

            # always include the app.json itself
            $ctxFiles += [pscustomobject]@{ path = $relAppJson; content = Get-Content $appJson -Raw }
            Write-Host "  Added app context: $relAppJson"

            # permissions / entitlements
            if ($IncludeAppPermissions) {
                Get-ChildItem -Path $appRoot -Recurse -Include '*.PermissionSet.al','*.Entitlement.al' |
                ForEach-Object {
                    $rel = [IO.Path]::GetRelativePath($repoRoot, $_.FullName) -replace '\\','/'
                    $ctxFiles += [pscustomobject]@{ path = $rel; content = Get-Content $_.FullName -Raw }
                    Write-Host "    └─ permissions: $rel"
                }
            }

            # markdown docs
            if ($IncludeAppMarkdown) {
                Get-ChildItem -Path $appRoot -Recurse -Filter '*.md' |
                ForEach-Object {
                    $rel = [IO.Path]::GetRelativePath($repoRoot, $_.FullName) -replace '\\','/'
                    $ctxFiles += [pscustomobject]@{ path = $rel; content = Get-Content $_.FullName -Raw }
                    Write-Host "    └─ docs: $rel"
                }
            }
        }
    }

    ############################################################################
    # 6. Insert AL-Guidelines into context
    ############################################################################

    # 0) Pattern hints. Only where a regex is realistically auto-detectable.
    #    Most readability rules are human-only; leave their pattern list empty.
    $PatternHints = @{
        'api-page'                 = '\b(PageType|QueryType)\s*=\s*API\b'
        'DeleteAll'                = '\bDeleteAll\s*\('
        'SetLoadFields'            = '\b(?:Set|RecordRef)\.?(?:Set)?LoadFields\s*\('
        'SetAutoCalcFields'        = '\bSetAutoCalcFields\s*\('
        'FindSet'                  = '\bFind(Set|First|Last)?\s*\('           # incl. FindFirst/FindLast
        'FieldError'               = '\bFieldError\s*\('
        'TransferFields'           = '\bTransferFields\s*\('
        'begin-as-an-afterword'    = '(?im)\b(?:then|else|do)\s*\r?\n\s*begin\b'
        'binary-operator-line-start' = '(?m)^[ \t]*(?:\+|-|\*|/|AND\b|OR\b|=)'
        'comments-spacing'         = '//[^ ]'                                # “//No space”
        'named-invocations'        = '\b(Page|Codeunit|Report|XmlPort|Query)\.Run(?:Modal)?\s*\(\s*\d+\s*,'
        'unnecessary-truefalse'    = '(?i)\b(?:not\s+\w+\s*)?=\s*(true|false)'
        'unnecessary-else'         = '\belse\s+(?:Error|Exit|Break|Skip|Quit)\('
        'istemporary-table-safeguard' = '\bDeleteAll\s*\('                   # same trigger as DeleteAll
        'if-not-find-then-exit'    = '\bFind(Set|First|Last)?\([^\)]*\)\s*then\b(?![^\r\n]*exit)'
        'lonely-repeat'            = '\brepeat\b.*'                          # very loose
        'one-statement-per-line'   = '(?m);[ \t]+\w'                            # “; somethingElse”
        'spacing-binary-operators' = '(?<! )(\+|-|\*|/|=|<>|<|>)(?! )'
        'variable-naming'          = '(?m)^\+\s*".+?"\s*:'
    }

    # 1) Load custom file if supplied. Overrides built-ins and auto-discover.
    if ($GuidelineRulesPath) {
        if (-not (Test-Path $GuidelineRulesPath)) {
            throw "GuidelineRulesPath not found: $GuidelineRulesPath"
        }
        switch ([IO.Path]::GetExtension($GuidelineRulesPath).ToLower()) {
            '.json' { $DefaultGuidelineRules = Get-Content $GuidelineRulesPath -Raw | ConvertFrom-Json }
            '.psd1' { $DefaultGuidelineRules = Import-PowerShellDataFile $GuidelineRulesPath }
            default { throw "Unsupported rules file type: $GuidelineRulesPath" }
        }
    }
    else {
        # 2) Enumerate every folder under /BestPractices at run time.
        $apiUrl = 'https://api.github.com/repos/microsoft/alguidelines/contents/content/docs/BestPractices'
        try {
            $dirList = Invoke-RestMethod -Uri $apiUrl -Headers @{ 'User-Agent' = 'al-reviewer' }
        } catch {
            throw "Unable to enumerate guideline folders: $_"
        }

        $DefaultGuidelineRules = @{}
        foreach ($dir in $dirList | Where-Object { $_.type -eq 'dir' }) {
            $name   = $dir.name            # e.g. 'DeleteAll', 'begin-as-an-afterword'
            $regexs = @()
            if ($PatternHints.ContainsKey($name)) {
                $regexs = @($PatternHints[$name])
            }
            $DefaultGuidelineRules[$name] = @{ folder = $name; patterns = $regexs }
        }
    }

    if (-not $DisableGuidelineDocs) {

        foreach ($f in $files) {
            $norm = Convert-PatchToCode -Patch ( $f.diffLines -join "`n" )
            Write-Host '::group::patch'
            Write-Host $norm.Text
            Write-Host '::endgroup::'
            $triggers = Get-TriggeredGuidelines -Patch $norm.Text

            foreach ($hit in $triggers) {
                # use the mapping to translate back to the unified-diff line no
                $diffLine = $norm.Map[$hit.Line]
                Write-Debug ("[DEBUG] {0,-30}  L{1,-5} ⇢  '{2}'" -f `
                            $hit.Rule, $diffLine, $hit.Snippet)

                $meta = $DefaultGuidelineRules[$hit.Rule]
                if (-not $meta) { continue }

                $doc = Get-GuidelineDoc -RuleName $hit.Rule -Folder $meta.folder
                if ($doc) {
                    $ctxFiles += [pscustomobject]@{
                        path    = "ALGuidelines/$($hit.Rule).md"
                        content = $doc
                    }
                }
            }
        }
    }

    ############################################################################
    # 7. Load context files (app.json's, readme's, alguidelines, custom files, ...)
    ############################################################################

    foreach ($glob in $ctxGlobs) {
        try {
            $blob = Invoke-GitHub -Path "/repos/$owner/$repo/contents/$($glob)?ref=$($pr.head.sha)"
            if ($blob.content) {
                $obj = [pscustomobject]@{
                    path    = $glob
                    content = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($blob.content))
                }
                $ctxFiles += $obj
                Write-Host " Added context file: $glob"
            }
        } catch {
            Write-Warning "Could not fetch context '$glob': $_"
        }
    }

    ############################################################################
    # 6. Gather linked issues
    ############################################################################
    $issueCtx = @()

    # a) IDs found in the PR body description (“#123”)
    # b) IDs returned by the GraphQL helper
    $issueIds = @() 
    $issueIds += Get-PRLinkedIssues -Owner $owner -Repo $repo -PrNumber $prNumber

    $issueIds  = $issueIds | Select-Object -Unique

    # if IssueCount > 0, truncate to that many
    if ($IssueCount -gt 0 -and $issueIds.Count -gt $IssueCount) {
        $issueIds = $issueIds[0..($IssueCount-1)]
    }

    foreach ($id in $issueIds) {
        try {
            $iss = Invoke-GitHub -Path "/repos/$owner/$repo/issues/$id"
        } catch {
            Write-Warning "Skipping issue #$($id): $_"
            continue
        }
        if (-not $FetchClosedIssues -and $iss.state -eq 'closed') {
            continue
        }
        $coms = Invoke-GitHub -Path "/repos/$owner/$repo/issues/$id/comments"
        $issueCtx += [pscustomobject]@{
            number   = $iss.number
            title    = $iss.title
            body     = $iss.body
            comments = $coms | ForEach-Object { @{ user=$_.user.login; body=$_.body } }
        }
        Write-Host " Added issue context: #$($iss.number) - $($iss.title)"
    }

    ############################################################################
    # 7. Build AI prompt & call AI
    ############################################################################
    $maxInline = if ($MaxComments -gt 0) { $MaxComments } else { 10 }

    $basePrompt = @"
You are reviewing AL code for Microsoft Dynamics 365 Business Central.

$BasePromptExtra

**When you answer:**
* Provide **up to $maxInline concise inline comments** if you spot something worth improving.
* Use the exact line number you see on either side of the hunk. If it's a removed line, the comment will go on the LEFT side.
* If you find nothing, set `"comments": []`.
* Keep acknowledgments short and neutral.
* Output GitHub-flavoured Markdown inside `"comment"` fields only.
* Return **valid JSON**. Inside "comment" fields you may use Markdown but MUST escape every \ as \\\\.

Focus exclusively on the code: naming, performance, events/trigger usage, filters,
record locking, permission/entitlement changes, UI strings (tone & BC terminology).

If a new object appears in code but not in any *.PermissionSet.al or .Entitlement.al, flag it.

Respond **only** with a JSON object using **exactly** these keys:

{
"summary"        : "<overall feedback - max 10 lines>",
"comments"       : [ { "path": "string", "line": number, "comment": "string (≤ 3 lines)" } ],
"suggestedAction": "approve" | "request_changes" | "comment",
"confidence"     : 0-1
}

Example of an empty-but-valid result:

{
"summary": "Looks good - no issues found.",
"comments": [],
"suggestedAction": "approve",
"confidence": 0.95
}
"@

    if ($lastCommit) {
        $basePrompt += "`nPrevious feedback already addressed can be omitted; focus on new changes."
    }

    $pullObj = @{
        title       = $pr.title
        description = $pr.body
        base        = $pr.base.sha
        head        = $pr.head.sha
    }

    $messages = @(
        @{ role = 'system'; content = $basePrompt },
        @{ role = 'user'; content = (
            @{
                type         = 'code_review'
                files        = $relevant | ForEach-Object { @{ path = $_.path; diff = $_.diff } }
                contextFiles = $ctxFiles
                pullRequest  = $pullObj
                issues       = $issueCtx
                context      = @{
                    repository     = $env:GITHUB_REPOSITORY
                    projectContext = $ProjectContext
                    isUpdate       = [bool]$lastCommit
                }
            } | ConvertTo-Json -Depth 6
        )}
    )

    $promptJson = $messages | ConvertTo-Json -Depth 8
    Write-Host '::group::Final prompt (JSON)'
    Write-Host ($promptJson | ConvertTo-Json -Compress)
    Write-Host '::endgroup::'

    Write-Host 'Calling API Endpoint...'
    $resp = Invoke-OpenAIChat -Messages $messages

    if ($resp -and $resp.PSObject.Properties.Name -contains 'usage') {
        $usage = $resp.usage
        if ($usage) {
            Write-Host "Tokens total: $($usage.total_tokens)  (prompt: $($usage.prompt_tokens), completion: $($usage.completion_tokens))"
        }
    } else {
        Write-Host "No token-usage info returned by provider."
    }

    $raw    = $resp.choices[0].message.content.Trim() -replace '^```json','' -replace '```$',''
    Write-Host "[DEBUG] Model returned:"
    Write-Host $raw

    # Model is nice and provides regex snippets (which break the json) -> sanitize any “\x” sequences where x != one of the valid JSON escapes
    $review = Convert-FromAiJson -Raw $raw
    $review.summary += "`n`n------`n`n_Code review performed by [BC-Reviewer](https://github.com/AidentErfurt/BC-AI-Reviewer) using $Model._"

    ########################################################################
    # 8. Build inline comment objects
    ########################################################################

    # keep at most $MaxComments, but only slice when needed
    if ($MaxComments -gt 0 -and $review.comments.Count -gt $MaxComments) {
        $review.comments = $review.comments[0..($MaxComments-1)]
    }

    $inline = foreach ($c in $review.comments) {

        $file = $relevant | Where-Object { $_.path -eq $c.path } | Select-Object -First 1
        if (-not $file) { continue }

        # --- validate the line number ------------------------------------------------
        [int]$ln = 0
        if (-not [int]::TryParse($c.line, [ref]$ln) -or $ln -le 0) {
            Write-Verbose "Skipping invalid line number '$($c.line)' in $($c.path)"
            continue
        }
        # -----------------------------------------------------------------------------

        $side = 'RIGHT'   # default

        # Did the model point at a *deleted* line?
        if ($file.rightMap.ContainsKey($ln)) {
            $side = 'RIGHT'
        } elseif ($file.leftMap.ContainsKey($ln)) {
            $side = 'LEFT'
        } else {
            Write-Verbose "Skipping unknown line $ln in $($file.path)"
            continue
        }

        # return a **hashtable** – not a PSCustomObject – so Add-ReviewComment receives
        # a [hashtable] and no type-conversion error is thrown
        @{
            path = $file.path
            line = $ln
            side = $side   # 'RIGHT' or 'LEFT'
            body = $c.comment
        }
    }

    # Cap inline comments only if a positive limit is specified (0 = unlimited)
    if ($MaxComments -gt 0) {
        if ($inline.Count -gt $MaxComments) {
            Write-Host "Truncating inline comments: showing only first $MaxComments of $($inline.Count)"
            $inline = $inline[0..($MaxComments - 1)]
        }
    }
    else {
        Write-Host "Posting all $($inline.Count) inline comments"
    }

    # ########################################################################
    # # 9. Create review
    # ########################################################################

    try {
        # 1. create the review (summary only)
        $reviewResponse = New-Review
        $reviewId = $reviewResponse.id
    } catch {
        Write-Warning "Submitting inline comments failed: $_  - falling back to summary-only"
    }

    Write-Host "Review complete for PR #$prNumber"

    # endregion
}

End {
    Write-Host 'Invoke-AICodeReview finished.'
}
}

# Auto‑invoke when the script is executed directly
if ($MyInvocation.InvocationName -notin @('.', 'source')) {
    Invoke-AICodeReview @PSBoundParameters
    return
}
