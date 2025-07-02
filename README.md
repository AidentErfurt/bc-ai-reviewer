# Aident Business Central AI Code Reviewer

[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)
[![Self-Test](https://github.com/AidentErfurt/bc-reviewer/actions/workflows/self-test.yml/badge.svg)](https://github.com/AidentErfurt/bc-reviewer/actions/workflows/self-test.yml)


Run an **AI-powered, Business Central–specific code review** on every pull request using **OpenAI**, **Azure OpenAI** *or* **OpenRouter.ai**.
The action fetches the PR diff, optional context files, and any referenced issues, sends them to the LLM, then posts a summary review and granular inline comments right on the PR.

**Highlights**

* Context-aware reviews: automatically pulls in `app.json`, permission sets, entitlements, READMEs/other `.md` docs, the latest Microsoft [AL-Guidelines](https://github.com/microsoft/alguidelines) pages *and* any issues/discussions referenced in the PR.
* Works with **Azure OpenAI**, **OpenAI** endpoints **and OpenRouter.ai** – choose the provider/model that fits your budget.
* Reviews are **incremental**: the bot ignores already-addressed feedback and comments only on new changes.
* Hard cap for inline-comment noise (`MAX_COMMENTS`).
* Fully configurable file-glob **include / exclude** filters.

## 📦 Usage

## Azure OpenAI - Example 1

| Why you’d use *this* example                                                | What it does                                                                                                                                                 |
| --------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **You already have an Azure OpenAI resource**                               | Connects the reviewer to *your* private Azure endpoint instead of the public OpenAI API (`AI_PROVIDER: azure`, `AZURE_ENDPOINT`, `AZURE_API_KEY`).           |
| **Your repo holds several Business Central apps (plus docs and pipelines)** | Limits the diff to AL, XLF and app.json files and injects extra prompt text about AppSource rules, localisation, docfx docs and AL-Go YAML.                  |
| **You care about context**                                                  | Automatically adds README/app.json files, linked issues and the latest AL-Guidelines to the prompt so the model can reason with more than just the raw diff. |
| **You ship from `main` and run the check on every PR update**               | Triggers on `pull_request` events of type **opened** and **synchronize** against the `main` branch.                                                          |


```yml
name: AI Code Review (Azure OpenAI)

on:
  pull_request:
    branches: [main]          # review PRs into main
    types:    [opened, synchronize]

permissions:
  contents:       read
  pull-requests:  write
  issues:         read        # linked issues are added to the prompt

jobs:
  review:
    runs-on: ubuntu-latest

    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0      # base & head commits are both needed for git diff

      - name: Run AI Code Reviewer
        uses: AidentErfurt/bc-reviewer@main
        with:
          GITHUB_TOKEN:      ${{ secrets.GITHUB_TOKEN }}

          # AI back-end (Azure OpenAI)
          AI_PROVIDER:       azure
          AZURE_ENDPOINT:    https://<your-resource>.openai.azure.com
          AZURE_API_KEY:     ${{ secrets.AZURE_OPENAI_KEY }}
          AZURE_API_VERSION: 2025-01-01-preview
          AI_MODEL:          o3-mini        # deployment name, not the base model

          # Review behaviour
          MAX_COMMENTS:      0              # unlimited inline comments

          # Prompt & repo context tweaks
          BASE_PROMPT_EXTRA: |
            You are reviewing **Business Central AppSource apps** plus supporting
            docs (docfx) and AL-Go pipelines.  Priorities:
              - correctness & performance of AL code
              - adherence to AppSource requirements
              - localisation quality in .xlf files
              - pipeline clarity (GitHub Actions / YAML)

          PROJECT_CONTEXT: |
            This repository contains:
              - several Business Central Apps
              - docfx-based documentation
              - an extended fork of AL-Go for GitHub
            Goal: consistent quality gates across all apps with minimal noise.

          # Diff scope filters
          INCLUDE_PATTERNS:  "**/*.al,**/*.xlf,**/app.json"
          EXCLUDE_PATTERNS:  ""

          # Misc
          FETCH_CLOSED_ISSUES:  false   # ignore already-closed issues

```

## OpenRouter.ai - Example 1

| Why you’d use this example               | What it does                                                                                                                              |
| ------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------- |
| **You just want to try the action quickly** | Uses the out-of-the-box defaults – no prompt tweaking, no file filters, no extra context.                                                 |
| **You have an OpenRouter.ai API key**       | Points the reviewer at [OpenRouter](https://openrouter.ai/) (`AI_PROVIDER: openrouter`) with only **three** required parameters: model name, API key, and provider. |
| **You want it on every pull request**       | The workflow triggers on *all* PR events (`on: pull_request`) across all branches.                                                        |

```yml
name: AI Review (OpenRouter - minimal)

on:
  pull_request:
    branches: [main]          # review PRs into main
    types:    [opened, synchronize]

permissions:
  contents:       read
  pull-requests:  write        # so the bot can add comments

jobs:
  review:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: AidentErfurt/bc-reviewer@main
        with:
          GITHUB_TOKEN:  ${{ secrets.GITHUB_TOKEN }}

          # the only three AI inputs you need
          AI_PROVIDER:   openrouter
          AI_MODEL:      microsoft/mai-ds-r1:free
          AI_API_KEY:    ${{ secrets.OPENROUTER_API_KEY }}

```

## OpenRouter.ai - Example 2

| Why you’d use this example                     | What it does                                                                                                                                                                                                |
| ---------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **You want targeted, *context-aware* reviews** | Adds an *extra system prompt* (`BASE_PROMPT_EXTRA`) and high-level project description (`PROJECT_CONTEXT`) so the model judges changes against your own standards, not generic rules.                       |
| **Your repo is a Business Central app**        | `AUTO_DETECT_APPS: true` automatically feeds each `app.json`, permission set, markdown doc & AL-Guidelines excerpts into the prompt, so the review understands your app architecture and BC best-practices. |
| **You use OpenRouter**                   | Same three core AI inputs as the minimal example (`AI_PROVIDER`, `AI_MODEL`, `AI_API_KEY`)                                                                            |
| **You only care about certain file types**     | `INCLUDE_PATTERNS` limits the diff to `*.al`, `*.rdlc`, `*.json` (skip pipelines, docs, etc.) which keeps token-usage low and feedback relevant.                                                            |
| **You want to keep the noise down**            | `MAX_COMMENTS: 5` hard-caps inline comments; the action will still post a summary review.                                                                                                                   |
| **You may want BC guideline details**          | `DISABLE_GUIDELINEDOCS: false` keeps automatic links to Microsoft AL-Guidelines in the context so the model can cite best-practice docs.                                                                    |
| **You need linked issues for context**         | Workflow grants `issues: read`; the action will pull referenced issues/discussions into the prompt so the AI can spot if a change really closes what it claims to close.                                    |

```yml
name: AI Code Review (OpenRouter)

on:
  pull_request:
    branches: [main]
    types:    [opened, synchronize]

permissions:
  contents: read
  pull-requests: write
  issues: read

jobs:
  review:
    runs-on: ubuntu-latest

    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - name: Run AI Code Reviewer
        uses: AidentErfurt/bc-reviewer@main
        with:
          GITHUB_TOKEN:   ${{ secrets.GITHUB_TOKEN }}

          # AI back-end
          AI_PROVIDER:    openrouter
          AI_MODEL:       microsoft/mai-ds-r1:free
          AI_API_KEY:     ${{ secrets.OPENROUTER_API_KEY }}

          # Review behaviour
          MAX_COMMENTS:   5

          #  repo context tweaks
          BASE_PROMPT_EXTRA: |
            Your extra prompt
          PROJECT_CONTEXT: |
            This repository hosts a Business Central PTE app.
          DISABLE_GUIDELINEDOCS: false
          AUTO_DETECT_APPS:    true    # enable app.json discovery
          INCLUDE_PATTERNS: "**/*.al,**/*.rdlc,**/*.json"
```

## 🔧 Inputs

| Name                  | Required                                               | Default                      | Description                                                               |
| --------------------- | ------------------------------------------------------ | ---------------------------- | ------------------------------------------------------------------------- |
| `GITHUB_TOKEN`        | **yes**                                                | -                            | Token with `contents:read`, `pull-requests:write`, **`issues:read`**      |
| `AI_PROVIDER`         | no                                                     | `azure`                      | `openai` \| `azure` \| `openrouter`                                       |
| `AI_MODEL`            | no                                                     | `gpt-4o-mini`                | Model name (OpenAI/OpenRouter) or deployment name (Azure)                 |
| `AI_API_KEY`          | required when `AI_PROVIDER` = `openai` or `openrouter` | -                            | Public OpenAI key or OpenRouter key                                       |
| `AZURE_ENDPOINT`      | required when `AI_PROVIDER` = `azure`                  | -                            | Azure OpenAI endpoint URL                                                 |
| `AZURE_API_KEY`       | required when `AI_PROVIDER` = `azure`                  | -                            | Azure OpenAI key                                                          |
| `AZURE_API_VERSION`   | no                                                     | `2024-05-01-preview`         | Azure API version                                                         |
| `MAX_COMMENTS`        | no                                                     | `0`                          | Hard cap for inline comments (0 = unlimited)                              |
| `PROJECT_CONTEXT`     | no                                                     | `""`                         | Free-form architectural tips for the model                                |
| `CONTEXT_FILES`       | no                                                     | `README.md`                  | Comma-separated globs always provided to the model                        |
| `INCLUDE_PATTERNS`    | no                                                     | `**/*.al,**/*.xlf,**/*.json` | Files to consider in review                                               |
| `EXCLUDE_PATTERNS`    | no                                                     | `""`                         | Globs to ignore                                                           |
| `ISSUE_COUNT`         | no                                                     | `0`                          | Max linked issues to fetch (`0` = all)                                    |
| `FETCH_CLOSED_ISSUES` | no                                                     | `true`                       | Include closed issues in 
| `BASE_PROMPT_EXTRA` | no       | `""`    | Extra text inserted into the system prompt *before* the hard-coded JSON-response instructions |
| `GUIDELINE_RULES_PATH` | no                                                   | `""`                                          | Path to JSON or PSD1 file defining custom AL-Guideline rules                                  |
| `DISABLE_GUIDELINEDOCS`| no                                                   | `false`                                       | Skip fetching the official Microsoft AL-Guidelines docs                                       |

> **Note:** There are **no outputs**; all feedback is posted directly to the PR.

## 🛠 How it works

1. The script detects the PR, gathers the diff and any previously addressed feedback.
2. Optional **context files** and **linked issues** (`#123` in the PR description) are fetched.
3. A structured prompt is sent to the chosen LLM.
4. The response (JSON) is parsed; a summary review + inline comments are posted via the GitHub REST API.
5. Subsequent runs only re-review commits newer than the last bot review.

## 💬 Contributing

Issues and PRs are welcome! Please open a discussion first for major feature changes.
All scripts are PowerShell 7.

## 🔒 Privacy & data flow

This action sends **file paths, unified-diff hunks and any extra context files you specify** to the
selected LLM endpoint (OpenAI, Azure OpenAI or OpenRouter).  
That means a subset of your repository contents will **leave the GitHub
environment and be processed by a third-party service**. Note that file paths & diff hunks may be logged by the provider for abuse-monitoring (per OpenAI/OpenRouter T&Cs)

Sensitive materials (credentials, customer data, unpublished crypto keys, …)
should therefore **not** appear in pull-request diffs or context files.

* OpenAI: see the official **API Data-Usage & Privacy policy**  
  <https://openai.com/policies/api-data-usage-policies>
* Azure OpenAI: see **Data, Privacy & Security for Azure OpenAI Service**  
  <https://learn.microsoft.com/legal/cognitive-services/openai/data-privacy>
* OpenRouter: see **Privacy, Logging, and Data Collection**  
  <https://openrouter.ai/docs/features/privacy-and-logging>

The action never stores your code or prompts itself. Everything is streamed
directly to the provider and the resulting review comments are written back to
the pull request.
