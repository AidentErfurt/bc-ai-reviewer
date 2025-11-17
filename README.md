# Aident Business Central AI Code Reviewer

[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)

Run an AI-powered, Business Central-specific code review on pull requests. This repo contains a GitHub composite action that:

- Collects the PR unified diff and optional context files (app.json, permission sets, markdowns, linked issues).
- Sends a structured prompt to your chosen LLM provider (Azure OpenAI, OpenAI, OpenRouter.ai).
- Posts a summary review and fine-grained inline comments on the PR.

This branch includes a new "always-pass-a-model" workflow: you must supply a MODELS_BLOCK (multiline YAML) which completely replaces the built-in models: block. The action merges that block into the bundled default config at runtime, substitutes any placeholders from environment variables, writes a runner-local merged config, and runs the reviewer.

Highlights
- Opinionated defaults and rules are bundled in the action (default-config.yaml) so users get sensible behaviour out-of-the-box.
- The MODELS_BLOCK input gives flexible model/provider selection (OpenAI, Azure, OpenRouter, local LLMs).
- Secrets (apiKey, apiBase when secret) are never committed — provide them via GitHub Secrets and interpolate in the MODELS_BLOCK or expose as runner env placeholders.
- Merge happens at runtime using `.github/actions/continue/merge-config.ps1` which substitutes placeholders of the form `{{NAME}}` from `env:NAME`.

Quick concepts
- MODELS_BLOCK (required): a multiline YAML string containing a `models:` array. It fully replaces the embedded `models:` section in default-config.yaml.
- Merged config: the action writes a merged YAML to `$RUNNER_TEMP/continue-config.yaml` and sets `CONTINUE_CONFIG` to that path before invoking the existing review scripts.
- Secrets: supply via `secrets.*` (interpolate directly in MODELS_BLOCK) or place placeholders like `apiKey: "{{AZURE_OPENAI_KEY}}"` and set the corresponding env var in the workflow.

Minimal example (recommended): inline MODELS_BLOCK using interpolated secrets

```yaml
# .github/workflows/review.yml
name: AI Code Review
on:
  pull_request:
    branches: [main]
    types: [opened, synchronize]

permissions:
  contents: read
  pull-requests: write
  issues: read

jobs:
  review:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with: { fetch-depth: 0 }

      - name: Run AI Code Reviewer
        uses: ./
        with:
          GITHUB_TOKEN: ${{ github.token }}
          
          MODELS_BLOCK: |
            models:
              - name: GPT-5 @Aident Azure OpenAI
                provider: azure
                model: gpt-5
                apiBase: https://your-azure-resource.openai.azure.com/openai/v1
                apiKey: ${{ secrets.AZURE_OPENAI_KEY }}
                roles: [chat, edit, apply]
                capabilities: [tool_use]
```

Placeholder substitution variant

If you prefer not to interpolate secrets directly in a long MODELS_BLOCK, use placeholders and set runner env vars. The merge helper replaces `{{NAME}}` with `$env:NAME` before writing the merged config.

```yaml
- name: Run AI Code Reviewer (placeholders)
  uses: ./
  env:
    AZURE_OPENAI_KEY: ${{ secrets.AZURE_OPENAI_KEY }}
  with:
    GITHUB_TOKEN: ${{ github.token }}
    MODELS_BLOCK: |
      models:
        - name: GPT-5 @Aident (placeholder)
          provider: azure
          model: gpt-5
          apiBase: https://your-azure-resource.openai.azure.com/openai/v1
          apiKey: "{{AZURE_OPENAI_KEY}}"
          roles: [chat, edit, apply]
```

Notes about secrets & safety
- Never commit real API keys or secrets into the repository. Use GitHub Secrets.
- The merged config is written to the runner's temporary folder (`$RUNNER_TEMP`) and is not committed. For extra caution you can delete the temp file after the action; the action does not upload it.
- The merge script performs placeholder substitution and will replace any `{{NAME}}` occurrences with the corresponding `env:NAME` value. If a placeholder has no matching env var, it will be replaced with an empty string by default (you can enable stricter validation if desired).

Recommended minimal action inputs / env handling
- The composite action accepts these important inputs:
  - GITHUB_TOKEN (required)
  - MODELS_BLOCK (required per "always pass a model")
  

Inside the composite action we set only the necessary runner envs for the script: `GITHUB_TOKEN`, `MODELS_BLOCK`. Runner-provided vars like `GITHUB_REPOSITORY`, `GITHUB_EVENT_PATH`, and `RUNNER_TEMP` are used directly by the scripts and must not be overridden.

Advanced: using a runtime models file
- If your models block is large, you can create a YAML file in a previous step (injecting secrets via env) and then pass its content into `MODELS_BLOCK` (e.g., `MODELS_BLOCK: ${{ steps.write.outputs.models }}`). Alternatively, I can add a `MODELS_FILE` input if you prefer passing a path.

Troubleshooting & tips
- If the reviewer prints errors about `CONTINUE_CONFIG` being invalid, ensure the action sets `CONTINUE_CONFIG` to the merged config path (the composite action does this automatically).
- If the model returns non-JSON or malformed JSON, the scripts attempt sanitisation and retries; inspect the uploaded CLI logs (artifact `.continue-logs/`) for raw provider output.
- To debug the merged config safely, we can add a `debug_preview` option that prints the merged YAML with `apiKey` fields redacted. Ask me to enable that if you want.

Where things live in this repo
- action.yml — the composite action entry point (wires steps and inputs).
- scripts/continue-review.ps1 — runner script that builds the prompt, calls the Continue CLI and posts GitHub reviews.
- .github/actions/continue/default-config.yaml — bundled template used when merging models.
- .github/actions/continue/merge-config.ps1 — runtime merge helper (replaces `models:` and substitutes placeholders).

Contributing
- PRs & issues welcome. For major feature requests please open a discussion first.

License & privacy
- Licensed under Apache 2.0. See LICENSE for details.
- This action sends diffs and selected context to third-party LLM providers. Do not include secrets or sensitive PII in your PR diffs or context files.

If you'd like, I can:
- add strict validation to fail when required model fields (provider/model/apiKey) are missing after substitution, or
- add `debug_preview` with redaction, or
- add `MODELS_FILE` input so you can pass a checked-in non-secret models.yaml while injecting secrets at runtime.

Pick one and I'll implement it next.

[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)

Run an AI-powered, Business Central-specific code review on pull requests. This repo contains a GitHub composite action that:

- Collects the PR unified diff and optional context files (app.json, permission sets, markdowns, linked issues).
- Sends a structured prompt to your chosen LLM provider (Azure OpenAI, OpenAI, OpenRouter.ai).
- Posts a summary review and fine-grained inline comments on the PR.

This branch includes a new "always-pass-a-model" workflow: you must supply a MODELS_BLOCK (multiline YAML) which completely replaces the built-in models: block. The action merges that block into the bundled default config at runtime, substitutes any placeholders from environment variables, writes a runner-local merged config, and runs the reviewer.

Highlights
- Opinionated defaults and rules are bundled in the action (default-config.yaml) so users get sensible behaviour out-of-the-box.
- The MODELS_BLOCK input gives flexible model/provider selection (OpenAI, Azure, OpenRouter, local LLMs).
- Secrets (apiKey, apiBase when secret) are never committed — provide them via GitHub Secrets and interpolate in the MODELS_BLOCK or expose as runner env placeholders.
- Merge happens at runtime using `.github/actions/continue/merge-config.ps1` which substitutes placeholders of the form `{{NAME}}` from `env:NAME`.

Quick concepts
- MODELS_BLOCK (required): a multiline YAML string containing a `models:` array. It fully replaces the embedded `models:` section in default-config.yaml.
- Merged config: the action writes a merged YAML to `$RUNNER_TEMP/continue-config.yaml` and sets `CONTINUE_CONFIG` to that path before invoking the existing review scripts.
- Secrets: supply via `secrets.*` (interpolate directly in MODELS_BLOCK) or place placeholders like `apiKey: "{{AZURE_OPENAI_KEY}}"` and set the corresponding env var in the workflow.

Minimal example (recommended): inline MODELS_BLOCK using interpolated secrets

```yaml
# .github/workflows/review.yml
name: AI Code Review
on:
  pull_request:
    branches: [main]
    types: [opened, synchronize]

permissions:
  contents: read
  pull-requests: write
  issues: read

jobs:
  review:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with: { fetch-depth: 0 }

      - name: Run AI Code Reviewer
        uses: ./
        with:
          GITHUB_TOKEN: ${{ github.token }}
          
          MODELS_BLOCK: |
            models:
              - name: GPT-5 @Aident Azure OpenAI
                provider: azure
                model: gpt-5
                apiBase: https://your-azure-resource.openai.azure.com/openai/v1
                apiKey: ${{ secrets.AZURE_OPENAI_KEY }}
                roles: [chat, edit, apply]
                capabilities: [tool_use]
```

Placeholder substitution variant

If you prefer not to interpolate secrets directly in a long MODELS_BLOCK, use placeholders and set runner env vars. The merge helper replaces `{{NAME}}` with `$env:NAME` before writing the merged config.

```yaml
- name: Run AI Code Reviewer (placeholders)
  uses: ./
  env:
    AZURE_OPENAI_KEY: ${{ secrets.AZURE_OPENAI_KEY }}
  with:
    GITHUB_TOKEN: ${{ github.token }}
    MODELS_BLOCK: |
      models:
        - name: GPT-5 @Aident (placeholder)
          provider: azure
          model: gpt-5
          apiBase: https://your-azure-resource.openai.azure.com/openai/v1
          apiKey: "{{AZURE_OPENAI_KEY}}"
          roles: [chat, edit, apply]
```

Notes about secrets & safety
- Never commit real API keys or secrets into the repository. Use GitHub Secrets.
- The merged config is written to the runner's temporary folder (`$RUNNER_TEMP`) and is not committed. For extra caution you can delete the temp file after the action; the action does not upload it.
- The merge script performs placeholder substitution and will replace any `{{NAME}}` occurrences with the corresponding `env:NAME` value. If a placeholder has no matching env var, it will be replaced with an empty string by default (you can enable stricter validation if desired).

Recommended minimal action inputs / env handling
- The composite action accepts these important inputs:
  - GITHUB_TOKEN (required)
  - MODELS_BLOCK (required per "always pass a model")
  

Inside the composite action we set only the necessary runner envs for the script: `GITHUB_TOKEN`, `MODELS_BLOCK`. Runner-provided vars like `GITHUB_REPOSITORY`, `GITHUB_EVENT_PATH`, and `RUNNER_TEMP` are used directly by the scripts and must not be overridden.

Advanced: using a runtime models file
- If your models block is large, you can create a YAML file in a previous step (injecting secrets via env) and then pass its content into `MODELS_BLOCK` (e.g., `MODELS_BLOCK: ${{ steps.write.outputs.models }}`). Alternatively, I can add a `MODELS_FILE` input if you prefer passing a path.

Troubleshooting & tips
- If the reviewer prints errors about `CONTINUE_CONFIG` being invalid, ensure the action sets `CONTINUE_CONFIG` to the merged config path (the composite action does this automatically).
- If the model returns non-JSON or malformed JSON, the scripts attempt sanitisation and retries; inspect the uploaded CLI logs (artifact `.continue-logs/`) for raw provider output.
- To debug the merged config safely, we can add a `debug_preview` option that prints the merged YAML with `apiKey` fields redacted. Ask me to enable that if you want.

Where things live in this repo
- action.yml — the composite action entry point (wires steps and inputs).
- scripts/continue-review.ps1 — runner script that builds the prompt, calls the Continue CLI and posts GitHub reviews.
- .github/actions/continue/default-config.yaml — bundled template used when merging models.
- .github/actions/continue/merge-config.ps1 — runtime merge helper (replaces `models:` and substitutes placeholders).

Contributing
- PRs & issues welcome. For major feature requests please open a discussion first.

License & privacy
- Licensed under Apache 2.0. See LICENSE for details.
- This action sends diffs and selected context to third-party LLM providers. Do not include secrets or sensitive PII in your PR diffs or context files.

