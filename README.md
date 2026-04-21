# Check Agent Readiness

[![Marketplace](https://img.shields.io/badge/marketplace-Check%20Agent%20Readiness-blue?logo=github)](https://github.com/marketplace/actions/check-agent-readiness)
[![Release](https://img.shields.io/github/v/release/lingzhong/agent-readiness-action?logo=github&sort=semver)](https://github.com/lingzhong/agent-readiness-action/releases)
[![CI](https://github.com/lingzhong/agent-readiness-action/actions/workflows/test.yml/badge.svg)](https://github.com/lingzhong/agent-readiness-action/actions/workflows/test.yml)
[![Lint](https://github.com/lingzhong/agent-readiness-action/actions/workflows/lint.yml/badge.svg)](https://github.com/lingzhong/agent-readiness-action/actions/workflows/lint.yml)
[![License: MIT](https://img.shields.io/github/license/lingzhong/agent-readiness-action)](LICENSE)

**Agent-readiness is the new SEO.** This Action gates your site's
agent-readiness level on every deploy, so regressions never reach
production. Drop it into your workflow — works with Cloudflare Pages,
Vercel, GitHub Pages, or any public URL.

```yaml
- name: Check Agent Readiness
  uses: lingzhong/agent-readiness-action@v0.1
  with:
    url: https://example.com
    min-level: 2
```

---

## How agent-ready is your site?

<table>
  <tr>
    <td align="center"><strong>Level 1 · Basic Web Presence</strong></td>
    <td align="center"><strong>Level 5 · Agent-Native</strong></td>
  </tr>
  <tr>
    <td><img src="docs/level%201.png" alt="isitagentready.com scan showing Level 1 (robots.txt + sitemap only)" width="580"></td>
    <td><img src="docs/level%205.png" alt="isitagentready.com scan showing Level 5 (full .well-known/ agent surface)" width="580"></td>
  </tr>
</table>

## Why

AI agents discover your site through well-known artifacts:
`/.well-known/agent-card.json`, MCP server cards, A2A descriptors, and
Agent Skills index files. If those regress — a 404 on the agent card, a
missing `transport` field, a stale skills index — agent traffic silently
drops. Catch it in CI, not in production.

This action calls an external agent-readiness scanner (default
[`isitagentready.com`](https://isitagentready.com)) against your freshly
deployed URL and fails CI if the detected level drops below a threshold.

## Levels

The scanner reports one of six levels based on which well-known artifacts
are present and valid:

| Level | Name              | Means |
|:-:|---|---|
| 0 | Not Ready         | No agent-discovery artifacts detected. |
| 1 | Basic Web Presence | `robots.txt` + `sitemap.xml`. |
| 2 | Bot-Aware         | Level 1 + `Content-Signal` directives. |
| 3 | Agent-Readable    | Level 2 + `Accept: text/markdown` content negotiation. |
| 4 | Agent-Integrated  | Level 3 + API Catalog + MCP Server Card + Agent Skills index. |
| 5 | Agent-Native      | Level 4 + OAuth Protected Resource Metadata + valid A2A Agent Card. |


## Usage

### Minimum

```yaml
- uses: lingzhong/agent-readiness-action@v0.1
  with:
    url: https://example.com
```

Default `min-level: 2` requires at least `Content-Signal` directives
(the Bot-Aware tier). Ratchet up as you build out `.well-known/`.

### With deploy preview

```yaml
jobs:
  deploy:
    runs-on: ubuntu-latest
    outputs:
      url: ${{ steps.publish.outputs.url }}
    steps:
      - id: publish
        # ...your deploy step, setting `url` output

  agent-readiness:
    needs: deploy
    runs-on: ubuntu-latest
    steps:
      - name: Check Agent Readiness
        uses: lingzhong/agent-readiness-action@v0.1
        with:
          url: ${{ needs.deploy.outputs.url }}
          min-level: 4
```

See [`examples/`](examples/) for full workflows for Cloudflare Pages,
Vercel, GitHub Pages, and custom servers.

### Soft-fail on scanner outage

This is the default: if the scanner API is unreachable or returns a
malformed response, the step emits a `::warning::` and passes. Your
deploy isn't blocked by a third-party outage. Set
`fail-on-scanner-unavailable: true` to flip to hard-fail.

### Soft-fail on any failure (including level regressions)

If you want the step to never fail the workflow — even on a real level
regression — use the native GitHub Actions knob:

```yaml
- uses: lingzhong/agent-readiness-action@v0.1
  continue-on-error: true
  with:
    url: https://example.com
```

`continue-on-error` is native GitHub Actions. We intentionally don't
re-implement it.

## Inputs

| Input | Required | Default | Purpose |
|---|---|---|---|
| `url` | yes | — | Target URL to scan. |
| `min-level` | no | `2` | Fail if detected level is below this (0–5; default `2` = Bot-Aware). |
| `wait-for-url` | no | `true` | Poll target until reachable before scanning. |
| `wait-timeout` | no | `60` | Max seconds to wait for target availability. |
| `wait-interval` | no | `3` | Seconds between target-URL reachability polls. |
| `scanner-endpoint` | no | `https://isitagentready.com/api/scan` | Override for self-hosted or alternative scanners. |
| `scanner-retries` | no | `3` | Retries on scanner API call. |
| `scanner-retry-delay` | no | `5` | Seconds between scanner retries. |
| `fail-on-scanner-unavailable` | no | `false` | If `true`, hard-fail when the scanner is unreachable or returns malformed output. Default `false` warns and passes. |
| `annotations` | no | `true` | Emit `::error::` / `::warning::` workflow commands. |

`wait-for-url` polls the **target URL**. `scanner-retries` retries the
**scanner API call**. Two separate retry loops; they don't overlap.

## Outputs

| Output | Type | Meaning |
|---|---|---|
| `level` | integer or empty | Parsed level from scanner; empty if the scan didn't complete. |
| `passed` | `'true'` / `'false'` | Whether the gate passed. |
| `response` | JSON string | Raw scanner response (truncated at ~900 KB to stay under GitHub's step-output limit). |

## Failure semantics (one rule)

- **Level regression** (`level < min-level`): hard fail.
- **URL unreachable** within `wait-timeout`: hard fail.
- **Scanner unavailable or malformed response**: governed by
  `fail-on-scanner-unavailable`. Default `false` warns and passes (so a
  third-party outage doesn't block your deploy).
- **Soft-fail on everything**: set `continue-on-error: true` on the step.

## Requirements

- `ubuntu-latest` or `macos-latest` runners — both preinstall the only
  two runtime dependencies, `curl` and `jq`.
- **Windows runners**: best-effort. The bash script runs under Git Bash
  and `curl` is available, but `jq` is not preinstalled. Install it in a
  prior step (e.g. `choco install jq -y`) if you need Windows. Windows is
  not exercised in our CI matrix.

## FAQ

### What do I do when this action fails?

Read the `::error::` annotation on the failing step — it names the
detected level (e.g. `level 2 (Bot-Aware)`) and enumerates the specific
checks to fix to reach the next level, pulled from the scanner's
`nextLevel.requirements` guidance. For example:

```
::error title=Agent Readiness regression: level 2 (Bot-Aware) < min 4::
Detected level 2 (Bot-Aware) (expected >= 4).
To reach level 3 (Agent-Readable), fix:
  - markdownNegotiation: Support Accept: text/markdown content negotiation...
Raw response in step output 'response'.
```

The guidance always points to the **next** level above the detected one
(here, level 3), not straight to `min-level`. Re-run after each fix to
climb one tier at a time. The full raw scanner response is in the step
output `response` for downstream tools to consume. Open the scanner's web UI at
[`isitagentready.com`](https://isitagentready.com) with your URL to see
full evidence per check.

### What if the scanner is down?

Default behavior: the step emits a `::warning::`, passes, and your
deploy proceeds. Set `fail-on-scanner-unavailable: true` to flip to
hard-fail.

### Can I self-host the scanner?

Yes — set `scanner-endpoint` to your own API. Response shape must match
what `isitagentready.com` returns (a JSON object with a numeric `level`
field, at minimum).

### Does this validate my local files before deploy?

No. This is a post-deploy gate against a live URL. Pre-flight local
linting of `.well-known/` files is a separate tool (not currently
shipped; may appear in the future).

## Standalone script usage

`scripts/check-readiness.sh` can be invoked outside GHA for local
debugging:

```bash
URL=https://example.com ./scripts/check-readiness.sh
```

This is best-effort for local development. The supported surface is the
composite Action.

## Contributing

See [`CONTRIBUTING.md`](CONTRIBUTING.md). By participating, you agree to
the [`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md).

## License

[MIT](LICENSE).
