# Codex Action

[![Tests](https://github.com/icoretech/codex-action/actions/workflows/test.yml/badge.svg)](https://github.com/icoretech/codex-action/actions/workflows/test.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

Run OpenAI Codex CLI non-interactively in GitHub Actions workflows via [codex-docker](https://github.com/icoretech/codex-docker).

---

## Quick Start

```yaml
- name: Run Codex
  id: codex
  uses: icoretech/codex-action@v0
  with:
    prompt: "Summarize these changes for operators"
    openai_api_key: ${{ secrets.OPENAI_API_KEY }}

- name: Use result
  run: echo "${{ steps.codex.outputs.result }}"
```

---

## Authentication Setup

You must provide exactly one of `openai_api_key` or `codex_config`. Providing both or neither will cause the action to fail immediately.

### Option A: API Key

1. Get an API key from [platform.openai.com/api-keys](https://platform.openai.com/api-keys).
2. Add it as a repository secret named `OPENAI_API_KEY`:
   **Settings → Secrets and variables → Actions → New repository secret**
3. Reference it in your workflow:

   ```yaml
   openai_api_key: ${{ secrets.OPENAI_API_KEY }}
   ```

---

### Option B: OAuth / Device Auth (`codex_config`)

Authenticate via device auth and store the resulting `auth.json` as a secret. This is useful for ChatGPT Pro/Plus subscribers who use Codex through their OpenAI account rather than an API key.

**How it works:** The device-auth flow produces an `auth.json` file containing OAuth tokens (access token, refresh token, account ID). Codex uses the access token to authenticate with OpenAI's API. When the access token expires, Codex automatically refreshes it using the refresh token — no keychain or browser required.

1. Pull the codex-docker image:

   ```bash
   docker pull ghcr.io/icoretech/codex-docker:0.115.0
   ```

2. Run the device auth flow (the `codex-bootstrap` helper forces file-based credential storage, which is required for CI):

   ```bash
   mkdir -p .codex
   docker run --rm -it \
     -v "$PWD/.codex:/home/codex/.codex" \
     ghcr.io/icoretech/codex-docker:0.115.0 \
     codex-bootstrap device-auth
   ```

3. Follow the browser prompt to complete authentication.

4. Verify the credentials were written:

   ```bash
   # You should see auth.json with OAuth tokens
   cat .codex/auth.json | python3 -c "import json,sys; d=json.load(sys.stdin); print('auth_mode:', d['auth_mode'])"
   ```

5. Encode the credentials file:

   ```bash
   # Linux
   base64 -w0 .codex/auth.json

   # macOS
   base64 -i .codex/auth.json
   ```

6. Store the output as a repository secret named `CODEX_CONFIG_B64`:
   **Settings → Secrets and variables → Actions → New repository secret**

7. Reference it in your workflow:

   ```yaml
   codex_config: ${{ secrets.CODEX_CONFIG_B64 }}
   ```

> **Token lifetime:** The access token expires frequently but is refreshed automatically using the refresh token. The refresh token itself eventually expires (typically weeks to months). When authentication starts failing, repeat steps 2–6 to obtain fresh tokens.

---

### Authentication Comparison

| | API Key | OAuth (Device Auth) |
|---|---|---|
| **Setup** | Simple (paste key) | Requires device-auth flow via Docker |
| **Token refresh** | Never expires (until revoked) | Auto-refreshes; refresh token expires after weeks/months |
| **Best for** | CI/CD with platform API access | ChatGPT Pro/Plus subscribers without a separate API key |
| **Credential file** | N/A (action runs `codex-bootstrap`) | `auth.json` with OAuth tokens |

---

### Optional: Custom Preferences (`codex_config_toml`)

You can pass a base64-encoded `config.toml` to customize Codex behavior (model defaults, personality, sandbox mode, etc.). This works with either authentication method.

1. Create a `config.toml` with your preferences:

   ```toml
   model = "o4-mini"
   sandbox_mode = "off"
   ```

2. Encode it:

   ```bash
   # Linux
   base64 -w0 config.toml

   # macOS
   base64 -i config.toml
   ```

3. Store the output as a repository secret (e.g., `CODEX_CONFIG_TOML_B64`) and reference it:

   ```yaml
   codex_config_toml: ${{ secrets.CODEX_CONFIG_TOML_B64 }}
   ```

> Note: The `model` and `reasoning_effort` action inputs take precedence over values in `config.toml` when both are provided.

---

## Inputs

| Input | Required | Default | Description |
|---|---|---|---|
| `prompt` | Yes | — | Instructions for Codex (e.g., `"Summarize these changes for operators"`). |
| `input_text` | No | `""` | Data to process (e.g., changelog content). Appended after the prompt with a `---` separator when provided. |
| `openai_api_key` | No | `""` | OpenAI API key. Mutually exclusive with `codex_config`. |
| `codex_config` | No | `""` | Base64-encoded `auth.json` from a prior device-auth session. Mutually exclusive with `openai_api_key`. |
| `codex_config_toml` | No | `""` | Base64-encoded `config.toml` with Codex preferences (model, personality, etc.). Works with either auth method. |
| `image_version` | No | `0.115.0` | codex-docker image version tag used for the container. |
| `model` | No | `""` | Model override passed to `codex exec --model`. When omitted, the model configured in your Codex config is used. |
| `reasoning_effort` | No | `""` | Reasoning effort level (`minimal`, `low`, `medium`, `high`, `xhigh`). Passed as `model_reasoning_effort` config override. |
| `network_access` | No | `false` | Allow Codex to make network requests (`curl`, `wget`, etc.) during execution. When `false`, a prompt-level policy instructs the model not to use networking tools. |
| `quiet` | No | `true` | Suppress verbose Codex output (tool calls, grep results, file reads) from workflow logs. Prevents source code leakage in CI logs. Set to `false` for debugging. |
| `timeout` | No | `300` | Maximum seconds allowed for Codex execution before the step is killed. |

---

## Outputs

| Output | Description |
|---|---|
| `result` | Text output produced by Codex. |

---

## Examples

### Changelog Summarization with git-cliff

Generate a changelog with [git-cliff](https://github.com/orhun/git-cliff), pass it to Codex for operator-friendly summarization, then use the result as a pull request body.

```yaml
name: Release Summary

on:
  push:
    tags:
      - 'v*'

jobs:
  summarize:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      pull-requests: write

    steps:
      - uses: actions/checkout@v6
        with:
          fetch-depth: 0

      - name: Generate changelog with git-cliff
        id: cliff
        run: |
          pip install git-cliff
          CHANGELOG=$(git cliff --latest --strip all)
          echo "changelog<<EOF" >> "$GITHUB_OUTPUT"
          echo "$CHANGELOG" >> "$GITHUB_OUTPUT"
          echo "EOF" >> "$GITHUB_OUTPUT"

      - name: Summarize changelog with Codex
        id: codex
        uses: icoretech/codex-action@v0
        with:
          prompt: |
            You are a technical writer. Summarize the following changelog
            into a concise, human-readable release summary suitable for
            an operator audience. Focus on user impact, not implementation
            details. Use bullet points.
          input_text: ${{ steps.cliff.outputs.changelog }}
          openai_api_key: ${{ secrets.OPENAI_API_KEY }}

      - name: Open release PR with summary
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
          SUMMARY: ${{ steps.codex.outputs.result }}
        run: |
          gh pr create \
            --title "Release ${{ github.ref_name }}" \
            --body "$SUMMARY" \
            --base main \
            --head "${{ github.ref_name }}"
```

---

### PR Description Generation

Automatically generate a pull request description by diffing the branch against the base.

```yaml
name: Generate PR Description

on:
  pull_request:
    types: [opened]

jobs:
  describe:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      pull-requests: write

    steps:
      - uses: actions/checkout@v6
        with:
          fetch-depth: 0

      - name: Get diff
        id: diff
        run: |
          DIFF=$(git diff origin/${{ github.base_ref }}...HEAD -- . ':(exclude)*.lock')
          echo "diff<<EOF" >> "$GITHUB_OUTPUT"
          echo "$DIFF" >> "$GITHUB_OUTPUT"
          echo "EOF" >> "$GITHUB_OUTPUT"

      - name: Generate description with Codex
        id: codex
        uses: icoretech/codex-action@v0
        with:
          prompt: |
            You are a senior engineer reviewing a pull request. Given the
            following git diff, write a clear PR description with these
            sections: Summary, Changes, and Testing Notes.
          input_text: ${{ steps.diff.outputs.diff }}
          openai_api_key: ${{ secrets.OPENAI_API_KEY }}

      - name: Update PR body
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
          DESCRIPTION: ${{ steps.codex.outputs.result }}
        run: |
          gh pr edit ${{ github.event.pull_request.number }} \
            --body "$DESCRIPTION"
```

---

### Code Review Summary

Run an automated code review on every pull request and post the result as a comment.

```yaml
name: Code Review

on:
  pull_request:
    types: [opened, synchronize]

jobs:
  review:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      pull-requests: write

    steps:
      - uses: actions/checkout@v6
        with:
          fetch-depth: 0

      - name: Get diff
        id: diff
        run: |
          DIFF=$(git diff origin/${{ github.base_ref }}...HEAD)
          echo "diff<<EOF" >> "$GITHUB_OUTPUT"
          echo "$DIFF" >> "$GITHUB_OUTPUT"
          echo "EOF" >> "$GITHUB_OUTPUT"

      - name: Review with Codex
        id: codex
        uses: icoretech/codex-action@v0
        with:
          prompt: |
            You are an experienced software engineer performing a code review.
            Analyze the following diff and provide:
            - A brief summary of what changed
            - Any potential bugs or logic errors
            - Security concerns if applicable
            - Suggestions for improvement
            Be concise and constructive.
          input_text: ${{ steps.diff.outputs.diff }}
          openai_api_key: ${{ secrets.OPENAI_API_KEY }}

      - name: Post review comment
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
          REVIEW: ${{ steps.codex.outputs.result }}
        run: |
          gh pr comment ${{ github.event.pull_request.number }} \
            --body "## Automated Code Review

          $REVIEW

          ---
          *Generated by [codex-action](https://github.com/icoretech/codex-action)*"
```

---

### Issue Triage with Cross-Repo Analysis

Automatically analyze new issues by cloning relevant repositories and posting an implementation plan as a comment. Codex explores the actual source code, references specific files and line numbers, and produces a grounded technical plan.

This recipe demonstrates:
- Fetching rich issue metadata (labels, comments, timeline, project board fields)
- Resolving issue signals (labels, title brackets, body mentions) to repository names
- Cloning matched repos so Codex can read the source code
- One-shot analysis with structured output and a bail-out mechanism
- Auto-labeling based on Codex's analysis
- Comment upsert (update existing comment on re-run instead of appending)

```yaml
name: Issue Triage

on:
  issues:
    types: [opened]
  workflow_dispatch:
    inputs:
      issue_number:
        description: 'Issue number to analyze'
        required: true
        type: number

concurrency:
  group: issue-triage-${{ github.event.issue.number || inputs.issue_number }}
  cancel-in-progress: true

jobs:
  triage:
    runs-on: ubuntu-latest
    permissions:
      issues: write
    env:
      ISSUE_NUMBER: ${{ github.event.issue.number || inputs.issue_number }}
    steps:
      # Wait for the author to finish editing (skip on manual dispatch)
      - name: Wait for issue to settle
        if: github.event_name == 'issues'
        run: sleep 300

      - name: Fetch issue details
        id: issue
        env:
          GH_TOKEN: ${{ github.token }}
        run: |
          repo="${{ github.repository }}"
          state=$(gh api "repos/${repo}/issues/${ISSUE_NUMBER}" --jq '.state')
          if [ "$state" != "open" ]; then
            echo "skip=true" >> "$GITHUB_OUTPUT"
            exit 0
          fi
          echo "skip=false" >> "$GITHUB_OUTPUT"

          gh api "repos/${repo}/issues/${ISSUE_NUMBER}" \
            --jq '{number, title, body, state, labels: [.labels[].name],
                   assignees: [.assignees[].login], user: .user.login,
                   created_at, comment_count: .comments}' > /tmp/issue.json

      # Clone repos mentioned in the issue (needs a PAT for private repos)
      - name: Clone relevant repos
        if: steps.issue.outputs.skip != 'true'
        env:
          GH_TOKEN: ${{ secrets.ORG_PAT }}
        run: |
          mkdir -p "$GITHUB_WORKSPACE/repos"
          # Extract repo names from labels, title brackets, body mentions
          # (your resolution logic here)
          for repo_name in $REPOS; do
            gh repo clone "your-org/$repo_name" \
              "$GITHUB_WORKSPACE/repos/$repo_name" \
              -- --depth=1 --no-single-branch 2>/dev/null || true
          done

      # Assemble context file for Codex
      - name: Prepare context
        if: steps.issue.outputs.skip != 'true'
        run: |
          mkdir -p "$GITHUB_WORKSPACE/repos"
          {
            echo "=== ISSUE ==="
            cat /tmp/issue.json
            echo ""
            echo "=== CLONED REPOS ==="
            for d in "$GITHUB_WORKSPACE/repos"/*/; do
              repo=$(basename "$d")
              echo "--- $repo ---"
              find "$d" -maxdepth 3 -not -path '*/.git/*' \
                -not -path '*/node_modules/*' | head -200
            done
          } > "$GITHUB_WORKSPACE/context.txt"

      - name: Analyze with Codex
        if: steps.issue.outputs.skip != 'true'
        id: analysis
        uses: icoretech/codex-action@v0
        with:
          prompt: |
            You are a senior engineering triage assistant. This is a ONE-SHOT
            analysis — do NOT ask questions or defer decisions.

            ## Execution environment
            You are running inside a read-only GitHub Actions workflow. Do NOT
            attempt git push, commit, or any state-modifying operations. Your
            purpose is to examine code and produce a written technical plan.

            ## Available tools
            Only: bash, git, grep, ripgrep (rg), sed, awk, find, cat, jq, curl.
            NO npm, node, python, or other runtimes are installed.

            ## Context
            Read /workspace/context.txt for issue details and repo listings.
            Source code is under /workspace/repos/ — explore it thoroughly.

            When linking to files, use GitHub URLs:
            https://github.com/your-org/{repo}/blob/{branch}/{path}#L{line}

            ## Output format
            1. **Repos involved** — which repo(s) and why
            2. **Analysis** — what the issue asks for, grounded in actual code
            3. **Implementation plan** — numbered steps with effort estimates
            4. **Risks and dependencies**
            5. **Assumptions**

            ## Auto-labeling
            At the very end, on a separate line:
            <!-- CODEX_LABELS: repo1,repo2,repo3 -->

            ## Bail-out
            If the issue is too vague, already resolved, or not code-related,
            respond with ONLY: SKIP
          openai_api_key: ${{ secrets.OPENAI_API_KEY }}
          network_access: 'false'
          timeout: '1800'

      - name: Post analysis comment
        if: >-
          steps.issue.outputs.skip != 'true'
          && steps.analysis.outputs.result != ''
          && steps.analysis.outputs.result != 'SKIP'
        env:
          GH_TOKEN: ${{ github.token }}
          CODEX_RESULT: ${{ steps.analysis.outputs.result }}
        run: |
          clean_result=$(printf '%s\n' "$CODEX_RESULT" \
            | sed '/<!-- CODEX_LABELS:.*-->/d')
          {
            echo "### Codex Triage Analysis"
            echo ""
            echo "> [!WARNING]"
            echo "> Automated preliminary analysis — may contain inaccuracies."
            echo ""
            printf '%s\n' "$clean_result"
          } > /tmp/comment.md

          # Upsert: update existing comment or create new
          existing=$(gh api \
            "repos/${{ github.repository }}/issues/${ISSUE_NUMBER}/comments?per_page=100" \
            --jq '[.[] | select(.body | contains("Codex Triage"))] | last | .id // empty')
          if [ -n "$existing" ]; then
            gh api "repos/${{ github.repository }}/issues/comments/${existing}" \
              -X PATCH -F "body=@/tmp/comment.md"
          else
            gh issue comment "$ISSUE_NUMBER" \
              --repo "${{ github.repository }}" --body-file /tmp/comment.md
          fi

      - name: Apply repo labels
        if: >-
          steps.issue.outputs.skip != 'true'
          && steps.analysis.outputs.result != ''
          && steps.analysis.outputs.result != 'SKIP'
        env:
          GH_TOKEN: ${{ github.token }}
          CODEX_RESULT: ${{ steps.analysis.outputs.result }}
        run: |
          labels=$(printf '%s\n' "$CODEX_RESULT" \
            | grep -o 'CODEX_LABELS: [^ ]*' | cut -d' ' -f2 || true)
          [ -z "$labels" ] && exit 0
          IFS=',' read -ra REPO_LABELS <<< "$labels"
          for label in "${REPO_LABELS[@]}"; do
            gh api "repos/${{ github.repository }}/issues/${ISSUE_NUMBER}/labels" \
              -X POST -f "labels[]=$label" 2>/dev/null || true
          done
```

**Key implementation notes:**

- **`safe.directory`**: codex-action automatically configures `GIT_CONFIG_GLOBAL` inside the Docker container, so Codex can run git commands on repos cloned by the runner without ownership errors.
- **`--no-single-branch`**: Cloning with this flag lets Codex check out non-default branches (e.g., `develop`, feature branches) when the issue refers to a specific environment.
- **Prompt engineering**: The prompt explicitly lists available tools (preventing wasted tokens on `npm: not found`), enforces read-only behavior, and includes a `SKIP` bail-out for non-code issues.
- **Comment upsert**: On re-runs, the workflow updates the existing triage comment instead of appending a new one.
- **Auto-labeling**: Codex outputs a hidden HTML comment with repo names; the workflow parses it and applies them as issue labels.

---

### Custom Analysis with Model Override

Use the `model` input to target a specific model for a particular task.

```yaml
name: Deep Analysis

on:
  workflow_dispatch:
    inputs:
      target_file:
        description: File to analyze
        required: true

jobs:
  analyze:
    runs-on: ubuntu-latest

    steps:
      - uses: actions/checkout@v6

      - name: Read target file
        id: content
        run: |
          CONTENT=$(cat "${{ github.event.inputs.target_file }}")
          echo "content<<EOF" >> "$GITHUB_OUTPUT"
          echo "$CONTENT" >> "$GITHUB_OUTPUT"
          echo "EOF" >> "$GITHUB_OUTPUT"

      - name: Analyze with Codex
        id: codex
        uses: icoretech/codex-action@v0
        with:
          prompt: |
            Perform a thorough security and correctness analysis of the
            following source file. Identify any vulnerabilities, edge cases,
            and areas that need hardening.
          input_text: ${{ steps.content.outputs.content }}
          openai_api_key: ${{ secrets.OPENAI_API_KEY }}
          model: o4-mini
          timeout: "600"

      - name: Print analysis
        run: echo "${{ steps.codex.outputs.result }}"
```

---

## Troubleshooting

### Authentication failure

**Symptoms:** The action fails early with an error referencing `codex-bootstrap api-key-login` or an authentication/authorization error from the Codex CLI.

**Fixes:**

- **API key auth:** Verify the secret `OPENAI_API_KEY` is set correctly in your repository and that the key is active at [platform.openai.com/api-keys](https://platform.openai.com/api-keys).
- **Config auth:** The OAuth token embedded in `auth.json` may have expired. Re-run the device-auth flow, re-encode the file, and update the `CODEX_CONFIG_B64` secret.

---

### Docker image pull failure

**Symptoms:** The action fails with a message like `Unable to find image 'ghcr.io/icoretech/codex-docker:...'` or an HTTP 429 / rate-limit error.

**Fixes:**

- Confirm the `image_version` input matches an available tag on [ghcr.io/icoretech/codex-docker](https://github.com/icoretech/codex-docker/pkgs/container/codex-docker).
- If you are hitting anonymous pull rate limits, authenticate your runner to GHCR by adding a `docker login` step before the action.

---

### Timeout

**Symptoms:** The step is killed after 300 seconds (the default) with a non-zero exit code.

**Fix:** Increase the `timeout` input:

```yaml
with:
  timeout: "600"
```

---

### Empty output

**Symptoms:** `steps.codex.outputs.result` is an empty string even though the step succeeded.

**Fixes:**

- Review your `prompt` — vague instructions can lead to empty or minimal responses.
- Check your OpenAI API status at [platform.openai.com/usage](https://platform.openai.com/usage).
- If using `input_text`, verify the input is not empty before the action runs.

---

### "Exactly one of openai_api_key or codex_config" error

**Symptoms:** The action fails immediately with:

```text
Exactly one of openai_api_key or codex_config must be provided, got both
```

or

```text
Exactly one of openai_api_key or codex_config must be provided, got neither
```

**Fix:** Provide exactly one authentication method. Remove the unused input or ensure the referenced secret is not empty. Both inputs default to `""`, so an unset secret resolves to an empty string and is treated as "not provided".

---

## Development

### Prerequisites

- [bats-core](https://github.com/bats-core/bats-core) for running the test suite
- [shellcheck](https://www.shellcheck.net/) for static analysis of the shell script

### Running tests

```bash
bats tests/entrypoint.bats
```

The test suite uses a mock `docker` binary (loaded from `tests/test_helper/mocks.bash`) so no real Docker daemon or network access is required.

### Running shellcheck

```bash
shellcheck entrypoint.sh
```

### How releases work

This repository uses [release-please](https://github.com/googleapis/release-please) with the `simple` release type. Merging a conventional-commit PR into `main` triggers release-please to open a release PR. When that release PR is merged:

1. A new semver tag (e.g., `v0.2.0`) is created automatically.
2. The `update-major-tag` job force-updates the corresponding major tag (e.g., `v0`) to point at the new release.

Users pinning to a major tag (e.g., `uses: icoretech/codex-action@v0`) always receive the latest patch and minor releases within that major automatically.
