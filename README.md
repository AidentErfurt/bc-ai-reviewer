# Aident Business Central AI Code Reviewer

[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)

Run an AI-powered, Business Central-specific code review on pull requests. This repository provides a GitHub composite action that:

- Collects the PR unified diff and optional context files (app.json, permission sets, markdowns, linked issues).
- Sends a structured prompt to your chosen LLM provider (Azure OpenAI, OpenAI, OpenRouter.ai).
- Posts a summary review and fine-grained inline comments on the PR.

## Highlights
- Opinionated defaults and rules are bundled in the action (default-config.yaml) for sensible behaviour out of the box.
- MODELS_BLOCK enables flexible model/provider selection (OpenAI, Azure, OpenRouter, local LLMs).
- Secrets (apiKey, apiBase if secret) are never committed — provide them via GitHub Secrets and either interpolate in MODELS_BLOCK or use 

## Quick concepts
- MODELS_BLOCK (required): a multiline YAML string containing a `models:` array. It fully replaces the embedded `models:` section in default-config.yaml.
- Merged config: the action writes a merged YAML to `$RUNNER_TEMP/continue-config.yaml` and sets `CONTINUE_CONFIG` to that path before invoking the review scripts.
- Secrets: supply via `secrets.*` (interpolate directly in MODELS_BLOCK) or use placeholders like `apiKey: "{{AZURE_OPENAI_KEY}}"` and set corresponding env vars in the workflow.

## Example workflow

```yaml
name: "BC Code Reviewer"
on:
  pull_request:
    branches: [ main ]
    types: [ opened, reopened, ready_for_review ]
  issue_comment:
    types: [created]
  workflow_dispatch:

permissions:
  contents: read
  pull-requests: write

jobs:
  review:
    # Only run if this is a pull_request event or an issue_comment on a PR that includes '/review'
    if: >
      (github.event_name == 'pull_request') ||
      (github.event_name == 'issue_comment' &&
       github.event.issue.pull_request != null &&
       contains(github.event.comment.body, '/review'))
    runs-on: ubuntu-latest

    # Optional but recommended to avoid overlapping runs on the same PR
    concurrency:
      group: ai-review-${{ github.event.pull_request.number || github.event.issue.number }}
      cancel-in-progress: true

    steps:
      - name: Checkout
        uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - name: Run AI Code Review
        uses: AidentErfurt/bc-ai-reviewer@main
        with:
          GITHUB_TOKEN: ${{ github.token }}
          MODELS_BLOCK: |
            models:
              - name: GPT-5 @Azure OpenAI w Responses API
                provider: azure
                model: gpt-5
                apiBase: https://your-azure-resource.openai.azure.com/openai/v1 # use a secret here
                apiKey: ${{ secrets.AZURE_OPENAI_KEY }}
                roles: [chat, edit, apply]
                requestOptions:
                  extraBodyProperties:
                    reasoning:
                      effort: high

          # Review configuration
          MAX_COMMENTS: 20
          AUTO_DETECT_APPS: true
          INCLUDE_APP_PERMISSIONS: true
          INCLUDE_APP_MARKDOWN: true
          INCLUDE_PATTERNS: "**/*.al,**/*.json"
          EXCLUDE_PATTERNS: ""
          CONTEXT_FILES: ""
          ISSUE_COUNT: 0
          FETCH_CLOSED_ISSUES: true
          BASE_PROMPT_EXTRA: ""
          DEBUG_PAYLOAD: true
          PROJECT_CONTEXT: |
            Repository contains Business Central AppSource Apps, related documentation based on docfx, and a slightly extended version of AL-Go for GitHub.
```

Note: The review can be re-triggered by commenting `/review` on the pull request (issue_comment event).

## Composite Action Inputs

These inputs are defined in action.yml (defaults in parentheses).

| Input | Type | Default | Description |
|---|:---:|---:|---|
| GITHUB_TOKEN | string | required | GitHub token with repo scope. Defaults to `github.token` when not passed explicitly. |
| MODELS_BLOCK | string (YAML) | required | Multiline YAML that fully replaces the default `models:` section. |
| APPROVE_REVIEWS | boolean | false | When true, the bot uses the model’s `suggestedAction` to choose APPROVE, REQUEST_CHANGES, or COMMENT for the summary review. |
| MAX_COMMENTS | number | 10 | Maximum inline comments to post (0 = unlimited; GitHub caps at 1000 per PR). |
| PROJECT_CONTEXT | string | "" | Optional architecture / guidelines text injected into the prompt. |
| CONTEXT_FILES | string | "" | Comma-separated globs for extra context files (read from HEAD). |
| INCLUDE_PATTERNS | string | "**/*.al" | Comma-separated globs to include in review. |
| EXCLUDE_PATTERNS | string | "" | Comma-separated globs to exclude from review. |
| ISSUE_COUNT | number | 0 | Max linked issues to fetch (0 = all). |
| FETCH_CLOSED_ISSUES | boolean | true | Include closed issues as context. |
| AUTO_DETECT_APPS | boolean | true | Discover app.json for changed files. |
| INCLUDE_APP_PERMISSIONS | boolean | true | Include `*.PermissionSet.al` and `*.Entitlement.al` for each relevant app. |
| INCLUDE_APP_MARKDOWN | boolean | true | Include `*.md` for each relevant app. |
| BASE_PROMPT_EXTRA | string | "" | Free-form text appended to the base review prompt. |
| DEBUG_PAYLOAD | boolean | false | When true, prints the JSON payload to logs (use sparingly; can be large). |
| SNIPPET_CONTEXT_LINES | number | 12 | Lines of context around each changed line in numbered snippets. |


## Runtime behavior (what the action does)

- Installs Node.js v20, `parse-diff`, and the [Continue CLI](https://docs.continue.dev/guides/cli); optionally installs `uv` for MCP integration.
- Merges continue [MODELS_BLOCK](https://docs.continue.dev/reference#models) into the bundled default-config.yaml at runtime via `.github/actions/continue/merge-config.ps1`, writes the merged file to `$RUNNER_TEMP`, and sets `CONTINUE_CONFIG`.
- Executes `scripts/continue-review.ps1` which:
  - Fetches the PR unified diff and parses it with `scripts/parse-diff.js`.
  - Filters changed files by INCLUDE_PATTERNS/EXCLUDE_PATTERNS.
  - Builds numbered snippets with SNIPPET_CONTEXT_LINES of surrounding context.
  - Optionally auto-discovers app.json and includes permissions and markdown files.
  - Assembles a structured prompt and invokes Continue CLI with `.continue/prompts/review-pr.md`.
  - Posts a summary review and up to MAX_COMMENTS inline comments. If APPROVE_REVIEWS is true, uses the model’s `suggestedAction` for the summary event.

## Troubleshooting & tips

- If the reviewer prints errors about `CONTINUE_CONFIG` being invalid, ensure the action sets it to the merged config path (the composite action does this automatically).
- If the model returns non-JSON or malformed JSON, the scripts attempt sanitisation and retries; inspect the uploaded CLI logs (artifact `.continue-logs/`) for raw provider output.
- Never commit real API keys or secrets. Use GitHub Secrets. The merged config is written to `$RUNNER_TEMP` and is not committed.

## Where things live in this repo

- `action.yml` — composite action entry point (wires steps and inputs).
- `scripts/continue-review.ps1` — runner script that builds the prompt, calls the Continue CLI and posts GitHub reviews.
- `.github/actions/continue/default-config.yaml` — bundled template used when merging models.
- `.github/actions/continue/merge-config.ps1` — runtime merge helper (replaces `models:` and substitutes placeholders).
- `scripts/parse-diff.js` — diff parsing helper used by the runner.

## Contributing

- PRs & issues welcome. For major feature requests please open a discussion first.

## License & privacy

- Licensed under Apache 2.0. See LICENSE for details.
- This action sends diffs and selected context to third-party LLM providers. Do not include secrets or sensitive PII in your PR diffs or context files.
