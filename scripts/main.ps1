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
Runs an AI-powered code review on a GitHub Pull Request using OpenAI, Azure OpenAI, or OpenRouter.

.DESCRIPTION
- Fetches the PR’s incremental diff (between last bot-reviewed commit or base SHA and the current head), 
  plus optional context files and linked issues (REST + GraphQL).
- Sends a numbered diff and compact context to the selected AI provider to generate JSON output 
  (summary + inline comments + suggested action).
- Posts a single PR review with inline comments (when positions are valid) or falls back to a summary-only review.

.PARAMETER GitHubToken
GitHub token with repo scope. Used for REST and GraphQL calls and to post the PR review.

.PARAMETER Provider
AI provider to call. One of: 'openai', 'azure', 'openrouter'. Default: 'azure'.

.PARAMETER Model
Base model name (e.g., 'o3-mini'). 
- OpenAI/OpenRouter: sent as the model in the request.
- Azure: set -AzureDeployment to your deployment’s friendly name; if omitted, the deployment name falls back to -Model.
Default: 'o3-mini'.

.PARAMETER ReasoningEffort
Reasoning effort hint for reasoning models ('low'|'medium'|'high'). Used with the Responses API when applicable.
Default: 'medium'.

# OpenAI / OpenRouter
.PARAMETER ApiKey
API key for OpenAI or OpenRouter. Required if -Provider is 'openai' or 'openrouter'.

.PARAMETER OpenRouterReferer
Optional HTTP Referer header value for OpenRouter analytics/attribution.

.PARAMETER OpenRouterTitle
Optional X-Title header value for OpenRouter.

# Azure OpenAI
.PARAMETER AzureEndpoint
Azure OpenAI endpoint, e.g. 'https://{resource-name}.openai.azure.com'. Required when -Provider 'azure'.

.PARAMETER AzureApiKey
Azure OpenAI API key. Required when -Provider 'azure'.

.PARAMETER AzureApiVersion
Azure OpenAI API version string. Default: '2025-01-01-preview'.

.PARAMETER AzureDeployment
Azure OpenAI deployment friendly name. If omitted, falls back to -Model as the deployment path segment.

# Review behavior
.PARAMETER ApproveReviews
If set, the review event mirrors the AI’s "suggestedAction" as APPROVE or REQUEST_CHANGES.
If not set, the review is posted as a COMMENT regardless of suggestions.

.PARAMETER MaxComments
Maximum number of inline comments to post. Use 0 for “no limit”.
Default: 10.

# Context & scoping
.PARAMETER ProjectContext
Free-form architectural notes or team guidelines to include in the prompt.

.PARAMETER ContextFiles
Comma-separated list of file globs (repo-relative) to always fetch and include as context (e.g. 'README.md,docs/*.md').

.PARAMETER IncludePatterns
Comma-separated glob patterns to include from the diff (matching file paths). 
Default: '**/*.al,**/*.xlf,**/*.json'.

.PARAMETER ExcludePatterns
Comma-separated glob patterns to exclude from the diff selection. Default: ''.

.PARAMETER IssueCount
Maximum number of linked issues (from PR body references and closingIssuesReferences) to include as context.
0 = include all found. Default: 0.

.PARAMETER FetchClosedIssues
If set, include closed issues in context; otherwise closed issues are skipped.

# App autodetect (Business Central)
.PARAMETER AutoDetectApps
If true, detects app.json files for touched files and includes per-app context.

.PARAMETER IncludeAppPermissions
When -AutoDetectApps is true, auto-include '*.PermissionSet.al' and '*.Entitlement.al' for each detected app. Default: $true.

.PARAMETER IncludeAppMarkdown
When -AutoDetectApps is true, auto-include '*.md' docs under each detected app. Default: $true.

# Guidelines & prompt add-ons
.PARAMETER BasePromptExtra
Additional free-form text appended to the base system prompt.

.PARAMETER GuidelineRulesPath
Path to a JSON or PSD1 rules file to seed AL-Guidelines patterns. If omitted, rules are autodiscovered from the public repo.

.PARAMETER DisableGuidelineDocs
Skip fetching guideline markdown docs (still uses pattern hits if available).

# Context shaping & logging
.PARAMETER IncludeChangedFilesAsContext
If true, also upload the HEAD versions of PR-touched files as read-only context (size-capped).

.PARAMETER LogPrompt
If set, logs a truncated JSON view of the final message payload for troubleshooting.

# Serena MCP (optional enrichment)
.PARAMETER EnableSerena
Enable Serena MCP enrichment (symbols overview and where-used queries).

.PARAMETER SerenaUrl
Serena MCP endpoint (if not supplied, uses SERENA_URL env var when present).

.PARAMETER SerenaTimeoutSec
Timeout (seconds) for each Serena call. Default: 20.

.PARAMETER SerenaMaxRefs
Maximum cross-references to include per symbol for where-used lookups. Default: 50.

.PARAMETER SerenaSymbolDepth
Depth for symbol search within file/solution. Default: 1.

.EXAMPLE
# Azure OpenAI with autodetected apps and extra docs
.\main.ps1 `
  -GitHubToken $env:GITHUB_TOKEN `
  -Provider azure `
  -AzureEndpoint 'https://my-aoai.openai.azure.com' `
  -AzureApiKey $env:AZURE_OPENAI_KEY `
  -AzureDeployment 'bc-reviewer-o3' `
  -AutoDetectApps $true -IncludeAppPermissions $true -IncludeAppMarkdown $true `
  -ContextFiles 'README.md,docs/*.md' `
  -MaxComments 20

.EXAMPLE
# OpenAI Responses API style when model name suggests it
.\main.ps1 `
  -GitHubToken $env:GITHUB_TOKEN `
  -Provider openai `
  -ApiKey $env:OPENAI_API_KEY `
  -Model 'o3-mini' `
  -IncludePatterns '**/*.al,**/*.json' `
  -ExcludePatterns '**/rdlc/**'

.EXAMPLE
# OpenRouter
.\main.ps1 `
  -GitHubToken $env:GITHUB_TOKEN `
  -Provider openrouter `
  -ApiKey $env:OPENROUTER_API_KEY `
  -Model 'openrouter/anthropic/claude-3.7' `
  -OpenRouterReferer 'https://example.com' -OpenRouterTitle 'BC Reviewer'

.INPUTS
None. All parameters are passed by name.

.OUTPUTS
None. Posts a PR review via the GitHub API.
#>

function Invoke-AICodeReview {
    [CmdletBinding(DefaultParameterSetName = 'Azure')]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$GitHubToken,

        [ValidateSet('openai','azure','openrouter')]
        [string]$Provider = 'azure',

        [string]$Model       = 'o3-mini',

        [ValidateSet('low','medium','high')]
        [string] $ReasoningEffort = 'medium',

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

        [string]$AzureApiVersion = '2025-01-01-preview',

        [Parameter(ParameterSetName='Azure')]
        [string]$AzureDeployment,

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
        [bool] $AutoDetectApps        = $false,
        [bool] $IncludeAppPermissions = $true,
        [bool] $IncludeAppMarkdown    = $true,
        [string] $BasePromptExtra,
        [string] $GuidelineRulesPath = '',
        [switch] $DisableGuidelineDocs,
        [bool] $IncludeChangedFilesAsContext = $false,
        [switch]$LogPrompt,

        # --- Serena MCP (optional) -------------------------------------------
        [bool]  $EnableSerena       = $false,
        [string]$SerenaUrl          = '',
        [int]   $SerenaTimeoutSec   = 20,
        [int]   $SerenaMaxRefs      = 50,
        [int]   $SerenaSymbolDepth  = 1
    )

Begin {

    Set-StrictMode -Version Latest

    ############################################################################
    # Helpers
    ############################################################################

    ############################################################################
    # Helper: retry + backoff
    ############################################################################
    function Invoke-WithRetry {
        param(
            [scriptblock]$Script,
            [int]$MaxAttempts = 5,
            [int]$BaseDelayMs = 500
        )
        for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
            try { return & $Script }
            catch {
                $isLast = $attempt -eq $MaxAttempts
                $status = $_.Exception.Response.StatusCode.value__
                if ($isLast -or ($status -lt 500 -and $status -ne 429)) { throw }
                Start-Sleep -Milliseconds ([int]([math]::Pow(2,$attempt-1) * $BaseDelayMs))
            }
        }
    }

    ############################################################################
    # Helper: Call OpenAI / Azure OpenAI / OpenRouter
    ############################################################################
    
    function Invoke-OpenAIChat {
        param([array]$Messages)

        # Heuristics: when to prefer the Responses API
        $isReasoningish = ($Model -match '^(?i)(o\d|gpt-?5)')

        # Build primary + fallback endpoints/headers/body per provider
        switch ($Provider) {
            'azure' {
                # Normalize endpoint
                $endpointNorm = ($AzureEndpoint ?? '').TrimEnd('/')
                $endpointNorm = $endpointNorm -replace '/openai$', ''   # strip accidental '/openai' etc.

                # Prefer explicit deployment; fall back to Model (back-compat)
                $deploymentName = if ($AzureDeployment) { $AzureDeployment } else { $Model }

                # Deployment path + URIs
                $deploymentPath = "$endpointNorm/openai/deployments/$deploymentName"
                $primaryUri  = if ($isReasoningish) { "${deploymentPath}/responses?api-version=$AzureApiVersion" }
                               else { "${deploymentPath}/chat/completions?api-version=$AzureApiVersion" }
                $fallbackUri = "${deploymentPath}/chat/completions?api-version=$AzureApiVersion"
                $hdr         = @{ 'api-key' = $AzureApiKey; 'Content-Type' = 'application/json' }

                # Bodies (keep base model in body; Azure uses deployment from URL)
                $bodyResponses = @{
                    model = $Model
                    input = $Messages
                    response_format = @{ type = 'json_object' }
                }
                if ($isReasoningish -and $ReasoningEffort) {
                    $bodyResponses.reasoning = @{ effort = $ReasoningEffort }
                }

                $bodyChat = @{
                    model    = $Model
                    messages = $Messages
                }
            }

            'openrouter' {
                # Chat Completions only
                $primaryUri  = 'https://openrouter.ai/api/v1/chat/completions'
                $fallbackUri = $primaryUri
                $hdr = @{ Authorization = "Bearer $ApiKey"; 'Content-Type' = 'application/json'; 'User-Agent'='bc-ai-reviewer' }
                if ($OpenRouterReferer) { $hdr.'HTTP-Referer' = $OpenRouterReferer }
                if ($OpenRouterTitle)   { $hdr.'X-Title'      = $OpenRouterTitle }

                $bodyChat = @{ model = $Model; messages = $Messages }
            }

            default { # 'openai'
                $primaryUri  = if ($isReasoningish) { 'https://api.openai.com/v1/responses' } else { 'https://api.openai.com/v1/chat/completions' }
                $fallbackUri = 'https://api.openai.com/v1/chat/completions'
                $hdr = @{ Authorization = "Bearer $ApiKey"; 'Content-Type' = 'application/json' }

                $bodyResponses = @{
                    model = $Model
                    input = $Messages
                    response_format = @{ type = 'json_object' }
                }
                if ($isReasoningish -and $ReasoningEffort) {
                    $bodyResponses.reasoning = @{ effort = $ReasoningEffort }
                }

                $bodyChat = @{
                    model    = $Model
                    messages = $Messages
                }
            }
        }

        # Helper to POST
        function Invoke-JsonPost([string]$uri,[hashtable]$hdr,[hashtable]$body) {
            Invoke-WithRetry {
                Invoke-RestMethod -Method POST -Uri $uri -Headers $hdr -Body ($body | ConvertTo-Json -Depth 10)
            }
        }

        # Prefer Responses when we picked it, fall back to Chat if unsupported
        $usingResponses = ($primaryUri -like '*/responses*')
        try {
            if ($usingResponses) {
                Write-Host "Provider: $Provider`nEndpoint: $primaryUri`nModel: $Model (Responses API)"
                return Invoke-JsonPost $primaryUri $hdr $bodyResponses
            } else {
                Write-Host "Provider: $Provider`nEndpoint: $primaryUri`nModel: $Model (Chat Completions)"
                return Invoke-JsonPost $primaryUri $hdr $bodyChat
            }
        }
        catch {
                # Only attempt fallback when our primary was Responses and the error looks like an unsupported route/arg
                $msg   = $_.Exception.Message
                $code  = $_.Exception.Response.StatusCode.value__  # may be null for some failures
                $looksUnsupported = $usingResponses -and ($code -in 400,404 -or $msg -match '(route|path).*(not found|unsupported|unknown)' -or $msg -match 'Unrecognized request argument.*input' -or $msg -match 'No such route'
            )

            if ($looksUnsupported -and $fallbackUri) {
                Write-Warning "Responses API not available for this deployment/API version. Falling back to Chat Completions."
                return Invoke-JsonPost $fallbackUri $hdr $bodyChat
            }

            throw  # real error; bubble up
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
            'User-Agent'           = 'bc-ai-reviewer'
        }
        if ($Body) { $Body = $Body | ConvertTo-Json -Depth 100 }
        try {
            Invoke-WithRetry { Invoke-RestMethod -Method $Method -Uri $uri -Headers $hdr -Body $Body }
        } catch {
            Write-Error "GitHub API call failed ($Method $Path): $_"
            throw
        }
    }

    ############################################################################
    # Helper: return every issue linked to the PR (GraphQL)
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
    nodes { number }         # issues closed by "Fixes/Closes #123"
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

        # fallback: plain "#123" mentions in the PR body 
        $mentioned = ([regex]'#(?<n>\d+)\b').Matches($prNode.body) |
                    ForEach-Object { [int]$_.Groups['n'].Value }

        # merge + dedupe + sort
        return ($closing + $mentioned | Select-Object -Unique | Sort-Object)
    }

    ########################################################################
    # Helper: normalise a git patch for guideline scanning
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
                '-' { continue }                     # pure deletion -> ignore
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
                    if ($snippet.Length -gt $MaxLen) { $snippet = $snippet.Substring(0,$MaxLen) + '...' }

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
                $md = Invoke-RestMethod -TimeoutSec 120 -Uri $url -Headers @{ 'Accept'='text/plain'; 'User-Agent'='al-reviewer' }
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
        $target = (Join-Path $dir 'app.json').Replace('\','/')
        $app    = $AllApps | Where-Object { $_ -eq $target }
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
        param($review, $inline)
        
        if ($review.summary.Length -gt 65000) {
            $review.summary = $review.summary.Substring(0,65000) + "`n...(truncated)"
        }
        $body = @{
            commit_id = $pr.head.sha          # optional but nice to be explicit
            body      = $review.summary
            event     = if ($ApproveReviews) { $review.suggestedAction.ToUpper() } else { 'COMMENT' }
            comments  = $inline               # array from step 3.2
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
        # 1) remove BOM/ZWSP and non-JSON control chars
        $json = $Raw.TrimStart([char]0xFEFF, [char]0x200B)
        $json = $json -replace '[\x00-\x08\x0B\x0C\x0E-\x1F]', ''
        # 2) escape stray backslashes
        $badBackslash = [regex]'(?<!\\)\\(?![\\/"bfnrtu]|u[0-9a-fA-F]{4})'
        for ($try = 1; $try -le $MaxAttempts; $try++) {
            try { return $json | ConvertFrom-Json }
            catch {
                $json = $badBackslash.Replace($json,'\\$&')
                Write-Verbose "Retry #$try - escaped stray back-slash or cleaned control chars"
            }
        }
        throw "Failed to sanitise AI response after $MaxAttempts attempts."
    }

    ############################################################################
    # Helper: download a unified diff for any two SHAs via the REST API
    ############################################################################
    function Get-PRDiff {
        param(
            [string]$Owner,
            [string]$Repo,
            [string]$BaseSha,
            [string]$HeadSha
        )
        # The compare-commits endpoint supports raw-diff if you ask for it:
        #   GET /repos/:owner/:repo/compare/:base...:head
        #   Accept: application/vnd.github.diff
        #
        # It already contains the per-file headers that parse-diff expects.
        Invoke-GitHub `
            -Path  "/repos/$Owner/$Repo/compare/$BaseSha...$HeadSha" `
            -Accept 'application/vnd.github.diff'
    }

    ############################################################################
    # Helper: get raw text of a file (HEAD version) - returns $null for binaries
    ############################################################################
    function Get-FileContent {
        param(
            [string]$Owner,
            [string]$Repo,
            [string]$Path,
            [string]$RefSha   # usually $pr.head.sha
        )

        try {
            $blob = Invoke-GitHub `
                    -Path "/repos/$Owner/$Repo/contents/$($Path)?ref=$RefSha"

            if ($blob.type -ne 'file' -or $blob.encoding -ne 'base64') { return $null }

            # skip obvious binaries (>200 KB **or** contains NUL)
            $bytes = [Convert]::FromBase64String($blob.content)
            if ($bytes.Length -gt 200KB) { return $null }
            if ($bytes -contains 0)      { return $null }

            return [System.Text.Encoding]::UTF8.GetString($bytes)
        }
        catch {
            Write-Warning "Could not fetch blob '$Path': $_"
            return $null
        }
    }

    function Get-PRFiles {
        param(
            [string]$Owner,
            [string]$Repo,
            [int]   $PrNumber
        )
        $page = 1; $all = @()
        do {
            $resp = Invoke-GitHub `
                    -Path "/repos/$Owner/$Repo/pulls/$PrNumber/files?per_page=100&page=$page"
            $all  += $resp
            $page++
        } while ($resp.Count -eq 100)
        return $all
    }

    ############################################################################
    # Helper: call Serena MCP (Streamable HTTP) tools
    ############################################################################

    # Thin wrapper so the rest of the script does not care about headers
    function Serena-Call([string]$Tool,[hashtable]$ToolArgs=@{}) {
        if (-not $EnableSerena -or [string]::IsNullOrWhiteSpace($SerenaUrl)) { return $null }
        Invoke-SerenaTool `
            -Url $SerenaUrl `
            -SessionId $SerenaSessionId `
            -SessionHdrName $SerenaSessionHdr `
            -Name $Tool `
            -ToolArgs $ToolArgs `
            -TimeoutSec $SerenaTimeoutSec
    }

    # Symbols:
    # get_symbols_overview gives a compact per-file map of procedures/triggers etc., 
    # which the model can use to anchor comments to the right places even when the diff is sparse.
    function Get-SerenaSymbolsOverview([string]$RelPath) {
        Serena-Call 'get_symbols_overview' @{ relative_path = $RelPath }
    }

    # Where-used: 
    # find_symbol -> find_referencing_symbols yields cross-refs for touched procedures/triggers, 
    # helping the reviewer flag knock-on effects and missing permission/entitlement updates without shipping entire files.
    function Find-SerenaSymbol([string]$NamePath,[string]$RelPath,[int]$Depth=1) {
        # The tool expects 'relative_path' (not 'within_relative_path')
        Serena-Call 'find_symbol' @{
            name_path     = $NamePath
            relative_path = $RelPath
            depth         = $Depth
            substring_matching = $true
        }
    }

    function Get-SerenaReferences([string]$NamePath,[string]$RelPath,[int]$Max=50) {
        # find_referencing_symbols requires BOTH name_path and relative_path
        $res = Serena-Call 'find_referencing_symbols' @{
            name_path     = $NamePath
            relative_path = $RelPath
        }
        $arr = @($res)
        if (-not $arr -or -not $arr.Count) { return @() }
        return $arr | Select-Object -First ([math]::Min($Max, $arr.Count))
    }

    function Normalize-SerenaSymbolsOverview {
        param($raw)

        if (-not $raw) { return @() }

        # 1) Already the final shape: object with .symbols
        if ($raw.PSObject.Properties['symbols']) {
            return @($raw.symbols)
        }

        # 2) Already an array of symbols
        if ($raw -is [System.Collections.IEnumerable] -and -not ($raw -is [string])) {
            return @($raw)
        }

        # 3) JSON string payloads (most common): try to parse
        $jsonText = $null
        if ($raw -is [string]) {
            $jsonText = $raw
        } elseif ($raw.PSObject.Properties['structuredContent'] -and $raw.structuredContent.result) {
            $jsonText = [string]$raw.structuredContent.result
        } elseif ($raw.PSObject.Properties['content'] -and $raw.content -and $raw.content[0].text) {
            $jsonText = [string]$raw.content[0].text
        }

        if ($jsonText) {
            try {
                $parsed = $jsonText | ConvertFrom-Json
                if ($parsed) { return @($parsed) }
            } catch { }
        }

        return @()
    }

    # Sererna path helpers
    function Get-RelTo {
        param([Parameter(Mandatory)][string]$Base,
            [Parameter(Mandatory)][string]$AbsPath)
        $rel = [IO.Path]::GetRelativePath($Base, $AbsPath)
        return ($rel -replace '\\','/')
    }

    function Get-AppRootForFile {
        param(
            [Parameter(Mandatory)][string]$RepoRoot,
            [Parameter(Mandatory)][string]$RepoRelPath,
            [Parameter(Mandatory)][string[]]$AllApps  # full paths to app.json files
        )
        $abs = Join-Path $RepoRoot $RepoRelPath
        $appJson = Get-NearestAppJson -Path $abs -AllApps $AllApps
        if ($appJson) { return (Split-Path $appJson -Parent) }
        return $RepoRoot   # fallback: repo-root as project
    }

    ###########################################################################
     # Helper: Serena snippet helpers
    ###########################################################################
    function Get-SerenaSymbolContent([string]$NamePath,[string]$RelPath) {
        # Primary: get_symbol_content (fast, body-only)
        $res = Serena-Call 'get_symbol_content' @{
            name_path     = $NamePath
            relative_path = $RelPath
        }
        if ($res -and $res.PSObject.Properties['text'] -and $res.text) { return $res }

        # Fallbacks (optional, only if your Serena build has these):
        try {
            $res2 = Serena-Call 'read_code_snippet' @{
                name_path     = $NamePath
                relative_path = $RelPath
            }
            if ($res2 -and $res2.PSObject.Properties['text'] -and $res2.text) { return $res2 }
        } catch {}

        return $null
    }
 
    function Get-ChangedSpansFromFile($fileObj) {
        # Returns array of @{ start = <int>; end = <int> } for HEAD (ln2) changes
        $lns = @()
        foreach ($chunk in $fileObj.chunks) {
            foreach ($chg in $chunk.changes) {
                if ($chg.ln2) { $lns += [int]$chg.ln2 }
            }
        }
        if (-not $lns) { return @() }
        $lns = $lns | Sort-Object -Unique
        # Merge contiguous lines into spans
        $spans = @()
        $s = $lns[0]; $e = $lns[0]
        for ($i=1; $i -lt $lns.Count; $i++) {
            if ($lns[$i] -eq $e + 1) { $e = $lns[$i]; continue }
            $spans += @{ start = $s; end = $e }
            $s = $lns[$i]; $e = $lns[$i]
        }
        $spans += @{ start = $s; end = $e }
        return $spans
    }
 
    function Get-SymbolRange($symItem) {
        # Normalise various schema shapes that Serena servers might return
        $start = $null; $end = $null
        if ($symItem.location -and $symItem.location.start -and $symItem.location.end) {
            $start = [int]$symItem.location.start.line
            $end   = [int]$symItem.location.end.line
        } elseif ($symItem.range -and $symItem.range.start -and $symItem.range.end) {
            $start = [int]$symItem.range.start.line
            $end   = [int]$symItem.range.end.line
        } elseif ($symItem.PSObject.Properties['start_line'] -and $symItem.PSObject.Properties['end_line']) {
            $start = [int]$symItem.start_line
            $end   = [int]$symItem.end_line
        }
        if (-not $start -or -not $end) { return $null }
        return @{ start = $start; end = $end }
    }

    # pull probable AL identifiers from head-side diff text
    function Get-AlIdentifiersFromDiff {
        param($FileObj)

        # Concatenate HEAD-side lines (ln2 != $null) from this file's diff
        $sb = [System.Text.StringBuilder]::new()
        foreach ($chunk in $FileObj.chunks) {
            foreach ($chg in $chunk.changes) {
                if ($chg.ln2) {
                    # strip a single leading "+" or " " if present in parse-diff payload
                    $line = $chg.content
                    if ($line.Length -gt 0 -and ($line[0] -eq '+' -or $line[0] -eq ' ')) {
                        $line = $line.Substring(1)
                    }
                    $null = $sb.AppendLine($line)
                }
            }
        }
        $text = $sb.ToString()
        if ([string]::IsNullOrWhiteSpace($text)) { return @() }

        $names = New-Object System.Collections.Generic.HashSet[string]

        # procedure / trigger names
        [regex]::Matches($text, '(?im)^\s*(?:local\s+)?procedure\s+([A-Za-z_][A-Za-z0-9_]*)') | ForEach-Object {
            $null = $names.Add($_.Groups[1].Value)
        }
        [regex]::Matches($text, '(?im)^\s*trigger\s+([A-Za-z_][A-Za-z0-9_]*)') | ForEach-Object {
            $null = $names.Add($_.Groups[1].Value)
        }

        # table/page field controls and actions/groups
        [regex]::Matches($text, '(?im)^\s*(field|action|group)\s*\(\s*(""(?:[^""]|"""")+""|""[^""]+""|[^,]+)\s*,') | ForEach-Object {
            $raw = $_.Groups[2].Value.Trim()
            $val = $raw.Trim('"') -replace '""','"'
            if ($val) { $null = $names.Add($val) }
        }

        # table fields in object definition: field(<id>;<Name>; <Type>)
        [regex]::Matches($text, '(?im)\bfield\s*\(\s*\d+\s*;\s*(""(?:[^""]|"""")+""|""[^""]+""|[A-Za-z_][A-Za-z0-9_]*)\s*;') | ForEach-Object {
            $raw = $_.Groups[1].Value
            $val = $raw.Trim('"') -replace '""','"'
            if ($val) { $null = $names.Add($val) }
        }

        # enum / enumextension names and values
        [regex]::Matches($text, '(?im)^\s*enum(?:extension)?\s+\d+\s+(""(?:[^""]|"""")+""|""[^""]+""|\w+)') | ForEach-Object {
            $val = $_.Groups[1].Value.Trim('"') -replace '""','"'
            if ($val) { $null = $names.Add($val) }
        }
        [regex]::Matches($text, '(?im)^\s*value\s*\(\s*\d+\s*;\s*(""(?:[^""]|"""")+""|""[^""]+""|\w+)') | ForEach-Object {
            $val = $_.Groups[1].Value.Trim('"') -replace '""','"'
            if ($val) { $null = $names.Add($val) }
        }

        return @($names)
    }
 
    function Test-Overlap($a, $b) {
    if (-not $a -or -not $b) { return $false }
        return ($a.start -le $b.end -and $b.start -le $a.end)
    }

    ###########################################################################
    # Helper: Client-side snippet slicer (HEAD content -> slice by line range)
    ###########################################################################
    function Get-RepoSnippet {
        param(
            [Parameter(Mandatory)][string]$Owner,
            [Parameter(Mandatory)][string]$Repo,
            [Parameter(Mandatory)][string]$Path,      # repo-relative
            [Parameter(Mandatory)][string]$RefSha,    # usually $pr.head.sha
            [Parameter(Mandatory)][hashtable]$Range,  # @{ start = <int>; end = <int> } (1-based, inclusive)
            [int]$PadBefore = 6,
            [int]$PadAfter  = 4,
            [int]$MaxBytes  = 8192
        )

        $text = Get-FileContent -Owner $Owner -Repo $Repo -Path $Path -RefSha $RefSha
        if (-not $text) { return $null }

        # Split into lines (robust to CRLF/LF)
        $lines = $text -split "`r?`n", 0

        # Clamp, pad, and slice (1-based input)
        $start = [math]::Max(1, [int]$Range.start - $PadBefore)
        $end   = [math]::Min($lines.Length, [int]$Range.end + $PadAfter)
        if ($end -lt $start) { return $null }

        $snippet = ($lines[($start-1)..($end-1)] -join "`n")

        # Keep snippet small; reduce padding first, then hard-trim if still large
        if ([Text.Encoding]::UTF8.GetByteCount($snippet) -gt $MaxBytes) {

            # progressively REDUCE padding from the requested PadBefore/PadAfter down to 0
            $maxShrink = [math]::Max($PadBefore, $PadAfter)
            for ($k = 0; $k -le $maxShrink; $k++) {
                $before = [math]::Max(0, $PadBefore - $k)
                $after  = [math]::Max(0, $PadAfter  - $k)

                $s2 = [math]::Max(1, [int]$Range.start - $before)
                $e2 = [math]::Min($lines.Length, [int]$Range.end + $after)

                $snippet = ($lines[($s2-1)..($e2-1)] -join "`n")
                if ([Text.Encoding]::UTF8.GetByteCount($snippet) -le $MaxBytes) {
                    $start = $s2; $end = $e2
                    break
                }
            }

            # if still too large, as a last resort do a hard byte-trim
            if ([Text.Encoding]::UTF8.GetByteCount($snippet) -gt $MaxBytes) {
                $bytes   = [Text.Encoding]::UTF8.GetBytes($snippet)
                $snippet = [Text.Encoding]::UTF8.GetString($bytes, 0, $MaxBytes)
                # note: may cut mid-line / mid-codepoint; acceptable for compact context
            }
        }

        return [pscustomobject]@{
            text           = $snippet
            start          = $start
            end            = $end
            original_range = $Range
        }
    }

    ############################################################################
    # Begin block: parameter validation, splitting globs, strict mode...
    ############################################################################

    # Serena integration
    . (Join-Path $PSScriptRoot 'serena-common.ps1')

    # Pull URL + session header negotiated during serena-handshake.ps1
    if ($EnableSerena -and -not $SerenaUrl -and $env:SERENA_URL) { $SerenaUrl = $env:SERENA_URL }
    $SerenaSessionId  = $env:SERENA_SESSION_ID
    $SerenaSessionHdr = if ($env:SERENA_SESSION_HDR) { $env:SERENA_SESSION_HDR } else { 'Mcp-Session-Id' }

    $ErrorActionPreference = 'Stop'
    Write-Host "Repository: $env:GITHUB_REPOSITORY  Provider: $Provider"
    if ($AzureEndpoint)      { Write-Host "::add-mask::$AzureEndpoint" }
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

    # Look for the most recent review by the bot that contains our marker
    $markerRx  = [regex]'<!--\s*ai-sha:(?<sha>[0-9a-f]{7,40})\s*-->'
    $lastSha   = $null
    $reviewHit = $null

    foreach ($rev in ($reviews | Sort-Object submitted_at -Descending)) {
        if ($rev.user.login -ne 'github-actions[bot]') { continue }
        $m = $markerRx.Match($rev.body)
        if ($m.Success) {
            $lastSha   = $m.Groups['sha'].Value
            $reviewHit = $rev
            break
        }
    }

    if ($lastSha) {
        Write-Host "Last-commit selection: marker-based (found <!-- ai-sha:$lastSha --> in review)"
        $lastCommit = $lastSha
    }
    else {
        # fall back to the timestamp method
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
            Write-Host "Last-commit selection: timestamp-based (fallback to latest bot review)"
        }
    }

    ############################################################################
    # 3. Fetch & parse diff   (incremental, via GitHub API)
    ############################################################################
    # Decide which commits to diff
    $baseRef = if ($lastCommit) { $lastCommit } else { $pr.base.sha }
    $headRef = $pr.head.sha

    # Ask GitHub for a raw unified diff between the two SHAs
    $patch = Get-PRDiff -Owner $owner -Repo $repo -BaseSha $baseRef -HeadSha $headRef

    if (-not $patch) {
        Write-Host "GitHub returned an empty diff - nothing to review."
        return
    }


    # Guard-rail first -> abort early if diff is huge
    $byteSize = [System.Text.Encoding]::UTF8.GetByteCount($patch)
    $maxBytes = 500KB
    if ($byteSize -gt $maxBytes) {
        throw "The generated diff is $($byteSize) bytes (> $maxBytes). Consider using INCLUDE_PATTERNS/EXCLUDE_PATTERNS."
    }

    # Parse with parse-diff via NodeJS
    $scriptJs = Join-Path $PSScriptRoot 'parse-diff.js'
    $pdOut    = $patch | node $scriptJs 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "parse-diff failed with exit code $LASTEXITCODE `n$pdOut"
    }
    $files    = $pdOut | ConvertFrom-Json

    # Write-Host "::endgroup::"
    
    # turn empty/null into an array so the rest of the pipeline is safe
    $files = @($files) | Where-Object { $_ }        # drop $null items
    if (-not $files.Count) {
        Write-Host "Patch is empty. Skipping review."
        return
    }

    # Write-Host "::group::Raw $files"
    # foreach ($f in $files) {
    #     $kind  = if ($f -is [pscustomobject]) { 'PSCustomObject' } else { $f.GetType().Name }
    #     $hasP  = $f -is [pscustomobject] -and $f.psobject.Properties['path']
    #     $text  = if ($hasP) { $f.path } else { '<no path>' }
    #     Write-Verbose ("{0,-15}  hasPath={1}  value={2}" -f $kind,$hasP,$text)
    # }
    # Write-Host "::endgroup::"

    $files = @($files)               # wrap null / scalar into an array
    if (-not $files) {               # still empty? -> nothing to review
        Write-Host "Patch is empty. Skipping review."
        return
    }

    Write-Host "::group::Files in patch"
    $files.path | ForEach-Object { Write-Host $_ }
    Write-Host "::endgroup::"

    ############################################################################
    # 4a. Filter files by include/exclude patterns
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

    if ($relevant.Count -eq 0) {
        Write-Host "No relevant files to review"
        return
    }

    # Cap to avoid GitHub's 1000 inline-comment limit
    $maxFiles = 300
    if ($relevant.Count -gt $maxFiles) {
        Write-Warning (
            "Limiting review to first {0} of {1} changed files (GitHub caps inline comments at 1000)." `
            -f $maxFiles, $relevant.Count
        )
        $relevant = $relevant[0..($maxFiles - 1)]
    }

    # Build validLines (which target lines are valid to comment on (head ln2))
    $validLines = @{}
    foreach ($f in $relevant) {
    $lines = foreach ($chunk in $f.chunks) {
        foreach ($chg in $chunk.changes) {
        if ($chg.ln2) { [int]$chg.ln2 }  # head-side only
        }
    }
    $validLines[$f.path] = $lines | Sort-Object -Unique
    }

    ############################################################################
    # 4a.1 Local HEAD snippets around changed spans (always on, low cost)
    ############################################################################
    $ctxFiles = @()
    Write-Host "::group::Local snippets from changed spans"
    $maxLocalSlicesPerFile = 8
    foreach ($f in $relevant) {
        $spans = Get-ChangedSpansFromFile $f
        if (-not $spans) { continue }

        $count = 0
        foreach ($span in $spans) {
            if ($count -ge $maxLocalSlicesPerFile) { break }
            $slice = Get-RepoSnippet -Owner $owner -Repo $repo -Path $f.path -RefSha $headRef `
                                    -Range $span -PadBefore 6 -PadAfter 4 -MaxBytes 8192
            if ($slice -and $slice.text) {
                $ctxFiles += [pscustomobject]@{
                    path    = "Local/Snippets/$($f.path)#L$($slice.start)-$($slice.end).al"
                    content = $slice.text
                }
                $count++
                Write-Host ("  + local slice: {0} L{1}-{2} ({3} chars)" -f $f.path,$slice.start,$slice.end,$slice.text.Length)
            }
        }
    }
    Write-Host "::endgroup::"

    ############################################################################
    # 4b. Add changed files themselves as extra context (optional)
    ############################################################################
    if ($IncludeChangedFilesAsContext) {
        Write-Host "::group::Adding changed files as context"
        $prFiles = Get-PRFiles -Owner $owner -Repo $repo -PrNumber $prNumber
        foreach ($f in $prFiles) {
            if ($f.status -eq 'removed') { continue }   # skip deleted files

            $content = Get-FileContent -Owner $owner -Repo $repo `
                                    -Path  $f.filename -RefSha $headRef
            if ($content) {
                $ctxFiles += [pscustomobject]@{
                    path    = $f.filename
                    content = $content
                }
                Write-Host "  + $($f.filename)"
            }
        }
        Write-Host "::endgroup::"
    }

    ############################################################################
    # 4c. Serena enrichment (optional): symbols, where-used, rich snippets
    #     - Group files by app (project) using nearest app.json
    #     - Activate the right project per group
    #     - Use project-relative paths for Serena tools
    ############################################################################
    $serenaIndex = @{ symbols = @{}; whereUsed = @{}; snippets = @{} }  # path -> overview, "path#symbol" -> refs[], code snippets map

    # Build app groups
    $repoRoot    = $Env:GITHUB_WORKSPACE
    $allAppJsons = @(Get-ChildItem -Path $repoRoot -Recurse -Filter 'app.json' |
                    ForEach-Object { $_.FullName.Replace('\','/') })

    # Map: AppRootAbs => [list of file objects from $relevant]
    $groups = @{}
    foreach ($f in $relevant) {
        $appRoot = Get-AppRootForFile -RepoRoot $repoRoot -RepoRelPath $f.path -AllApps $allAppJsons
        if (-not $groups.ContainsKey($appRoot)) {
            $groups[$appRoot] = New-Object System.Collections.Generic.List[object]
        }
        $groups[$appRoot].Add($f)
    }

    if ($EnableSerena) { Write-Host "::group::Serena enrichment" }

    foreach ($appRoot in $groups.Keys) {

        # Switch Serena to the correct project (idempotent; ok if already active)
        if ($EnableSerena -and $SerenaUrl) {
            Serena-Call 'activate_project' @{ project = $appRoot } | Out-Null
            Write-Host "Activating Serena project: $appRoot"
        }

        foreach ($f in ($groups[$appRoot] | Where-Object { $_.path -like '*.al' })) {
            $sym = $null
            # Compute path RELATIVE to the current Serena project (app root)
            $absFile       = Join-Path $repoRoot $f.path
            $relProjectPath = Get-RelTo -Base $appRoot -AbsPath $absFile   # e.g. "HelloWorld.al"

            # Per-file symbols overview (Serena)
            $sym = $null  # reset per file
            if ($EnableSerena -and $SerenaUrl) {
                $symRaw   = Get-SerenaSymbolsOverview -RelPath $relProjectPath
                $symList  = Normalize-SerenaSymbolsOverview $symRaw  # <-- robust across shapes

                if ($symList -and $symList.Count) {
                    # Store a compact JSON artifact; avoid double-encoding when $symRaw is already a JSON string
                    $ctxContent = if ($symRaw -is [string]) { $symRaw } else { ($symList | ConvertTo-Json -Depth 10) }
                    $ctxFiles += [pscustomobject]@{
                        path    = "Serena/Symbols/$($f.path).json"
                        content = $ctxContent
                    }

                    # Keep an object around that has a .symbols-like field for downstream code
                    $sym = [pscustomobject]@{ symbols = $symList }
                    $serenaIndex.symbols[$f.path] = $sym  # index uses normalized shape
                    Write-Host "  + symbols: $($f.path)  ⇢  [$relProjectPath]"
                } else {
                    # still keep a safe empty symbol set so downstream checks are simple
                    $sym = [pscustomobject]@{ symbols = @() }
                }
            }

            # Identify overlapping symbols (changed lines ↔ symbol ranges)
            $defs = @()
            if ($EnableSerena -and $SerenaUrl -and $sym) {
                $spans = Get-ChangedSpansFromFile $f
                $symList = @($sym.symbols)
                foreach ($item in $symList) {
                    $r = Get-SymbolRange $item
                    if (-not $r) { continue }
                    foreach ($span in $spans) {
                        if (Test-Overlap $r $span) {
                            # record the symbol once
                            $defs += [pscustomobject]@{
                                name      = ($item.name_path ?? $item.name ?? $item.symbol ?? '<unknown>')
                                name_path = ($item.name_path ?? $item.name ?? $item.symbol ?? '<unknown>')
                                type      = ($item.type ?? $item.kind ?? 'symbol')
                                range     = $r
                            }
                            break
                        }
                    }
                }
                # de-duplicate by name_path
                $defs = $defs | Sort-Object name_path -Unique
            }

            # diff-driven symbol resolution (targeted)
            # If overview didn't give us ranges for everything, try resolving identifiers
            # seen in the diff and add any with ranges to $defs.
            $maxResolvedPerFile = 20
            $resolved = 0
            $knownKeys = @{}
            foreach ($d in $defs) { $knownKeys[$d.name_path] = $true }

            $alNames = Get-AlIdentifiersFromDiff $f
            foreach ($name in $alNames) {
                if ($resolved -ge $maxResolvedPerFile) { break }
                # Skip if we already have a symbol with this name_path
                if ($knownKeys.ContainsKey($name)) { continue }

                $hit = Find-SerenaSymbol -NamePath $name -RelPath $relProjectPath -Depth $SerenaSymbolDepth
                if (-not $hit) { continue }

                # Prefer the first good candidate with a range
                foreach ($symHitItem in @($hit)) {
                    $r = Get-SymbolRange $symHitItem
                    if ($r) {
                        $defs += [pscustomobject]@{
                            name      = ($symHitItem.name ?? $name)
                            name_path = ($symHitItem.name_path ?? $name)
                            type      = ($symHitItem.type ?? $symHitItem.kind ?? 'symbol')
                            range     = $r
                        }
                        $knownKeys[$symHitItem.name_path] = $true
                        $resolved++
                        Write-Host ("    └─ resolved: {0}  L{1}-{2}" -f $symHitItem.name_path,$r.start,$r.end)
                        break
                    }
                }
            }
            # de-dup after adding newly resolved items
            $defs = $defs | Sort-Object name_path -Unique          

            # Fetch code snippets for those changed symbols (client-side slicing first)
            if ($defs -and $defs.Count) {
                foreach ($d in $defs) {
                    $source = 'client-slice'

                    # 1) Prefer client-side slicing from HEAD content by symbol range
                    $slice = Get-RepoSnippet -Owner $owner -Repo $repo -Path $f.path -RefSha $headRef -Range $d.range -PadBefore 6 -PadAfter 4 -MaxBytes 8192

                    # 2) Optional fallback via Serena (if available)
                    if (-not $slice -and $EnableSerena -and $SerenaUrl) {
                        $maybe = Get-SerenaSymbolContent -NamePath $d.name_path -RelPath $relProjectPath
                        if ($maybe -and $maybe.text) {
                            $slice = [pscustomobject]@{
                                text           = $maybe.text
                                start          = $d.range.start
                                end            = $d.range.end
                                original_range = $d.range
                            }
                            $source = 'serena'
                        }
                    }

                    if ($slice -and $slice.text) {
                        $key = "$($f.path)#$($d.name_path)"
                        $serenaIndex.snippets[$key] = @{
                            type   = $d.type
                            range  = $d.range
                            bytes  = ([Text.Encoding]::UTF8.GetByteCount($slice.text))
                            from   = $source
                        }
                        $ctxFiles += [pscustomobject]@{
                            path    = "Serena/Snippets/$($f.path)#$($d.name_path).al"
                            content = $slice.text
                        }
                        Write-Host ("    └─ snippet: {0} ({1}, len={2})" -f $d.name_path, $source, $slice.text.Length)
                    }
                }
            }


            # Where-used per changed symbol (trimmed), now that $defs is defined
            if ($EnableSerena -and $SerenaUrl -and $defs -and $defs.Count) {
                foreach ($d in $defs) {
                    $symHit   = Find-SerenaSymbol -NamePath $d.name_path -RelPath $relProjectPath -Depth $SerenaSymbolDepth
                    $namePath = if ($symHit -and $symHit[0] -and $symHit[0].name_path) { $symHit[0].name_path } else { $d.name_path }
                    $refs     = Get-SerenaReferences -NamePath $namePath -RelPath $relProjectPath -Max $SerenaMaxRefs
                    if ($refs -and $refs.Count) {
                        $key = "$($f.path)#$namePath"
                        $serenaIndex.whereUsed[$key] = $refs
                        $ctxFiles += [pscustomobject]@{
                            path    = "Serena/WhereUsed/$key.json"
                            content = ($refs | ConvertTo-Json -Depth 10)
                        }
                        Write-Host "    └─ where-used: $namePath ($($refs.Count))"
                    }
                }
            }
        }
    }

    if ($EnableSerena) { Write-Host "::endgroup::" }

    # Cap context payload (~700 KB). Remove largest entries first.
    $maxCtxBytes = 700KB
    $ctxBytes = ($ctxFiles | ForEach-Object {
        [Text.Encoding]::UTF8.GetByteCount($_.content)
    } | Measure-Object -Sum).Sum

    if ($ctxBytes -gt $maxCtxBytes) {
        $ctxFiles = $ctxFiles | Sort-Object {
            [Text.Encoding]::UTF8.GetByteCount($_.content)
        } -Descending

        while ($ctxBytes -gt $maxCtxBytes -and $ctxFiles.Count -gt 0) {
            $removeBytes = [Text.Encoding]::UTF8.GetByteCount($ctxFiles[0].content)
            $ctxFiles = $ctxFiles | Select-Object -Skip 1
            $ctxBytes -= $removeBytes
        }
    }

    ###########################################################################
    # 5. Autodetect app context
    ###########################################################################

    if ($AutoDetectApps) {
        # 1) figure out where the checked-out repo lives
        $repoRoot    = $Env:GITHUB_WORKSPACE
        if (-not (Test-Path $repoRoot)) {
            throw "Cannot find GITHUB_WORKSPACE at '$repoRoot'"
        }

        # 2) enumerate all app.json in the repo
        Write-Host "::group::Detect app structure & context"
        $allAppJsons = @(Get-ChildItem -Path $repoRoot -Recurse -Filter 'app.json' |
                        ForEach-Object { $_.FullName.Replace('\','/') })
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
        Write-Host "::endgroup::"

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
        'comments-spacing'         = '//[^ ]'                                # "//No space"
        'named-invocations'        = '\b(Page|Codeunit|Report|XmlPort|Query)\.Run(?:Modal)?\s*\(\s*\d+\s*,'
        'unnecessary-truefalse'    = '(?i)\b(?:not\s+\w+\s*)?=\s*(true|false)'
        'unnecessary-else'         = '\belse\s+(?:Error|Exit|Break|Skip|Quit)\('
        'istemporary-table-safeguard' = '\bDeleteAll\s*\('                   # same trigger as DeleteAll
        'if-not-find-then-exit'    = '\bFind(Set|First|Last)?\([^\)]*\)\s*then\b(?![^\r\n]*exit)'
        'lonely-repeat'            = '\brepeat\b.*'                          # very loose
        'one-statement-per-line'   = '(?m);[ \t]+\w'                            # "; somethingElse"
        'spacing-binary-operators' = '(?<! )(\+|-|\*|/|=|<>|<|>)(?! )'
        'variable-naming'          = '(?m)^\s*".+?"\s*:'
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
            $dirList = Invoke-RestMethod -TimeoutSec 120 -Uri $apiUrl -Headers @{ 'User-Agent' = 'al-reviewer' }
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

        # convert git diff to al code
        $norm = Convert-PatchToCode -Patch $patch
        # Write-Host "::group::Git diff (normalized)"
        # Write-Host $norm.Text
        # Write-Host "::endgroup::"
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
    # 7. Gather linked issues
    ############################################################################    
    $issueCtx = @()

    # a) IDs found in the PR body description ("#123")
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
    # 8. Build AI prompt & call AI
    ############################################################################
    $maxInline = if ($MaxComments -gt 0) { $MaxComments } else { 1000 }

$IsUpdate = [bool]$lastCommit

$rubric = @"
<review_rubric>
  <quality_gates>
    - AL analyzers enabled (CodeCop, UICop, AppSourceCop; PerTenantExtensionCop for PTEs) and important diagnostics addressed.
    - DataClassification set (avoid ToBeClassified) when adding/altering table fields.
    - ObsoleteState/ObsoleteTag used when deprecating symbols; avoid deprecated APIs.
    - New objects covered by PermissionSet/Entitlement with least privilege.
  </quality_gates>
  <performance>
    - Prefer set-based ops: FindSet + repeat...until Next() = 0 over FindFirst in loops.
    - Avoid IsEmpty() before FindSet() unless justified.
    - Use SetLoadFields/partial records when iterating or reading few fields.
    - Be cautious with COMMIT; keep transactions small. Consider CommitBehavior in sensitive flows.
  </performance>
  <ui_text_and_tooltips>
    - Pages/Reports: include ApplicationArea and UsageCategory so objects appear in Search.
    - ToolTips: present and concise; field ToolTips start with "Specifies ...".
    - Use Labels for user-facing strings (Message/Error/Confirm); avoid hardcoded literals.
  </ui_text_and_patterns>
  <architecture_and_style>
    - Prefer Enums (extensible) over Options for new work; use interfaces for pluggable logic.
    - Encapsulate internals (Access = Internal; use façades/public contracts).
    - Follow MS naming/formatting; keep procedures cohesive and single-purpose.
    - Prefer events (publish/subscribe) over modifying base logic.
  </architecture_and_style>
  <testing_and_tooling>
    - Add small test codeunits for critical logic; use TransactionModel appropriately.
    - Add telemetry/logging where it helps supportability (no personal data).
  </testing_and_tooling>
  <review_etiquette>
    - Only claim issues you can see in the diff or context; if something is likely but not shown, add it to the summary as a suggestion and lower confidence.
    - Don't ask the human to clarify mid-review. If you assume something, note it under "Assumptions" in the summary.
    - Keep inlines ≤ 3 lines; aggregate overflow in the summary.
  </review_etiquette>
</review_rubric>
"@

$basePrompt = @"
<code_review_task>
  <role>AI reviewer for Microsoft Dynamics 365 Business Central repositories.</role>
  <objectives>
    - Assess code quality & AL best practices
    - Find bugs / edge cases / locking or concurrency risks
    - Call out performance concerns (filters, keys, FlowFields)
    - Judge readability & maintainability
    - Surface security gaps (permissions/entitlements)
  </objectives>
</code_review_task>

<project_context>
$ProjectContext
</project_context>

<guidance>
  - Provide up to $maxInline concise inline comments; aggregate overflow in the summary.
  - If nothing needs improvement, set "comments": [].
  - Use GitHub-flavoured Markdown only inside "comment" fields; plain text elsewhere.
  - Do not rely on contextFiles for inline comments.
  - Inline comments must reference a {path,line} present in the numbered diff and the validLines table.
</guidance>

$rubric

<additional_inputs>
 - local snippets: files under "Local/Snippets/*" are HEAD code slices around changed lines; prefer them for reasoning over the raw unified diff.
 - serena symbols: "Serena/Symbols/*.json" are per-file symbol overviews (metadata only; may lack ranges).
 - serena snippets: "Serena/Snippets/*#<symbol>.al" are code slices for resolved symbols.
 - where-used: "Serena/WhereUsed/*#<symbol>.json" are trimmed cross-references; use to discuss impact/ripple effects, not for anchoring inline comments.
</additional_inputs>

<reasoning_effort>$ReasoningEffort</reasoning_effort>

<output_contract>
  Respond with a single JSON object (no code fences) using exactly:
  {
    "summary"        : "<overall feedback - max 10 lines>",
    "comments"       : [ { "path": "string", "line": number, "comment": "string (≤ 3 lines)" } ],
    "suggestedAction": "approve" | "request_changes" | "comment",
    "confidence"     : 0-1
  }
  Escape JSON strings (quotes, backslashes) correctly.
</output_contract>

<notes>
$(
  if ($IsUpdate) { 'Previous feedback already addressed can be omitted; focus on new changes.' } else { '' }
)
</notes>

<extra>
$BasePromptExtra
</extra>
"@


    $pullObj = @{
        title       = $pr.title
        description = $pr.body
        base        = $pr.base.sha
        head        = $pr.head.sha
    }

    # Build a number-prefixed diff for each file
    $numberedFiles = foreach ($f in $relevant) {
        # collect each change line with its target line number.
        $lines = foreach ($chunk in $f.chunks) {
            foreach ($chg in $chunk.changes) {
            # prefer the new-file line number (ln2) if available, otherwise original (ln)
            $ln = if ($chg.ln2) { $chg.ln2 } elseif ($chg.ln) { $chg.ln } else { continue }
            # prefix: "<line> <content>". Like "42 +    AddedCode()"
            "$ln $($chg.content)"
            }
        }

        [pscustomobject]@{
            path = $f.path
            diff = ($lines -join "`n")
        }
    }

    ############################################################################
    # Final context size cap (drop largest entries first)
    ############################################################################
    $maxCtxBytesTotal = 900KB
    $ctxBytes = ($ctxFiles | ForEach-Object {
        [Text.Encoding]::UTF8.GetByteCount($_.content)
    } | Measure-Object -Sum).Sum

    if ($ctxBytes -gt $maxCtxBytesTotal) {
        $ctxFiles = $ctxFiles | Sort-Object {
            [Text.Encoding]::UTF8.GetByteCount($_.content)
        } -Descending

        while ($ctxBytes -gt $maxCtxBytesTotal -and $ctxFiles.Count -gt 0) {
            $removeBytes = [Text.Encoding]::UTF8.GetByteCount($ctxFiles[0].content)
            $ctxFiles = $ctxFiles | Select-Object -Skip 1
            $ctxBytes -= $removeBytes
        }
    }

    # Send that numbered diff to the model
    $messages = @(
    @{ role = 'system'; content = $basePrompt },
    @{ role = 'user';   content = (
        @{
            type         = 'code_review'
            files        = $numberedFiles
            validLines   = $validLines
            contextFiles = $ctxFiles
            pullRequest  = $pullObj
            issues       = $issueCtx
            serena       = $serenaIndex
            context      = @{
            repository     = $env:GITHUB_REPOSITORY
            projectContext = $ProjectContext
            isUpdate       = [bool]$lastCommit
            }
            changeSummary = $pr.title
        } | ConvertTo-Json -Depth 10
        )
    }
    )

    if ($LogPrompt) {
        $promptJson = $messages | ConvertTo-Json -Depth 10
        if ($promptJson.Length -gt 20000) { $promptJson = $promptJson.Substring(0,20000) + "`n...(truncated)" }
        Write-Host "::group::Final prompt (JSON)"
        Write-Host $promptJson
        Write-Host "::endgroup::"
    }

    Write-Host "Calling API Endpoint..."
    $resp = Invoke-OpenAIChat -Messages $messages

    if ($resp -and $resp.PSObject.Properties.Name -contains 'usage') {
        $usage = $resp.usage
        if ($usage) {
            Write-Host "Tokens total: $($usage.total_tokens)  (prompt: $($usage.prompt_tokens), completion: $($usage.completion_tokens))"
        }
    } else {
        Write-Host "No token-usage info returned by provider."
    }

    # Extract text for Chat or Responses API
    $raw = $null

    # 1) Chat Completions
    if ($resp.PSObject.Properties.Name -contains 'choices' -and $resp.choices.Count) {
        $raw = $resp.choices[0].message.content
    }

    # 2) Responses API variants
    if (-not $raw) {
        # a) output_text (common)
        if ($resp.PSObject.Properties.Name -contains 'output_text' -and $resp.output_text) {
            $raw = $resp.output_text
        }
        # b) output[].content[] blocks
        elseif ($resp.PSObject.Properties.Name -contains 'output' -and $resp.output.Count) {
            $block = $resp.output[0].content | Where-Object { $_.type -eq 'output_text' -or $_.type -eq 'text' } | Select-Object -First 1
            if ($block) { $raw = $block.text }
        }
        # c) content[].text (some preview payloads)
        elseif ($resp.PSObject.Properties.Name -contains 'content' -and $resp.content.Count) {
            $c0 = $resp.content[0]
            if ($c0.PSObject.Properties.Name -contains 'text') { $raw = $c0.text }
        }
    }

    if ($raw) { $raw = $raw.Trim() -replace '^```json','' -replace '```$','' }

    if (-not $resp -or -not $raw) {
         $msg = "AI provider returned no content:`n$(($resp | ConvertTo-Json -Depth 6))"
         Write-Error $msg
         return      # or   throw $msg
     }

    Write-Host "[DEBUG] Model returned: "
    Write-Host $raw

    # Model is nice and provides regex snippets (which break the json) -> sanitize any "\x" sequences where x != one of the valid JSON escapes
    # Finds any single backslash that is not immediately followed by ", \, /, b, f, n, r, t or u, and doubles it.
    # This turns \s into \\s (which JSON then interprets as the literal characters \ + s) without touching \n or \".
    $raw = $raw -replace '\\(?!["\\/bfnrtu])','\\\\'

    $review = Convert-FromAiJson -Raw $raw
    if ($Provider -eq 'azure') {
        $dn = if ($AzureDeployment) { $AzureDeployment } else { $Model }
        $review.summary += "`n`n------`n`nCode review performed by [BC-Reviewer](https://github.com/AidentErfurt/BC-AI-Reviewer) using $Model (deployment: $dn)."
    } else {
        $review.summary += "`n`n------`n`nCode review performed by [BC-Reviewer](https://github.com/AidentErfurt/BC-AI-Reviewer) using $Model."
    }
    
    $review.summary += "`n<!-- ai-sha:$headRef -->"

    ########################################################################
    # 9. Map inline comments & submit review
    ########################################################################

    # for a given file+line, which side LEFT or RIGHT does GitHub expect?
    $sideMap = @{}

    foreach ($f in $relevant) {
    $sides = @{}
    foreach ($chunk in $f.chunks) {
        foreach ($chg in $chunk.changes) {
        switch ($chg.type) {
            'add' { $sides[[int]$chg.ln2] = 'RIGHT' }
            'del' { $sides[[int]$chg.ln]  = 'LEFT'  }
            default { if ($chg.ln2) { $sides[[int]$chg.ln2] = 'RIGHT' } }
        }
        }
    }
    $sideMap[$f.path] = $sides
    }

    $inline = @(
        foreach ($c in $review.comments) {
            if ($sideMap.ContainsKey($c.path)) {
                $fileSideMap = $sideMap[$c.path]
                if ($fileSideMap.ContainsKey([int]$c.line)) {
                    [pscustomobject]@{
                        path = $c.path
                        line = [int]$c.line
                        side = $fileSideMap[[int]$c.line]   # LEFT / RIGHT
                        body = $c.comment
                    }
                }
            }
        }
    )

    # Early-exit if nothing survived
    if (-not $inline) {
        Write-Warning 'AI produced no valid inline comments; summary-only review will be posted.'
    }

    # Enforce overall cap
    if ($MaxComments -gt 0 -and $inline.Count -gt $MaxComments) {
        Write-Host "Truncating inline comments: showing only first $MaxComments of $($inline.Count)"
        $inline = $inline[0..($MaxComments - 1)]
    } else {
        Write-Host "Posting all $($inline.Count) inline comments"
    }

    ########################################################################
    # 10. Create review
    ########################################################################

    try {
        # first attempt: summary + inline comments
        $reviewResponse = New-Review -review $review -inline $inline
        Write-Host "Review (with inlines) posted: $($reviewResponse.html_url)"

    }
    catch {
        $err      = $_
        $errMsg   = if ($err.ErrorDetails) {
                        $err.ErrorDetails.Message
                    } else {
                        $err.Exception.Message
                    }

        if ($errMsg -match 'Pull request review thread line must be part of the diff') {
            Write-Warning 'Inline positions rejected by GitHub - falling back to summary-only review.'

            # Add the orphaned inline remarks to the summary itself
            if ($inlineOrig = $review.comments) {
                $extras = $inlineOrig | ForEach-Object {
                    "* **$($_.path):$($_.line)** - $($_.comment)"
                } | Out-String
                $review.summary += "`n`n### Additional remarks:`n$extras"
            }

            try {
                $inline = @()                  # summary-only retry
                $reviewResponse = New-Review -review $review -inline $inline
                Write-Host "Summary-only review posted: $($reviewResponse.html_url)"
            }
            catch {
                Write-Error "Even summary-only review failed: $($_.Exception.Message)"
                throw
            }
        }
        else {
            Write-Error "Submitting review failed: $errMsg"
            throw
        }
    }

    Write-Host "Review complete for PR #$prNumber"
    }

End {
    Write-Host "Invoke-AICodeReview finished."
}
}

# Auto-invoke when the script is executed directly
if ($MyInvocation.InvocationName -notin @('.', 'source')) {
    Invoke-AICodeReview @PSBoundParameters
    return
}