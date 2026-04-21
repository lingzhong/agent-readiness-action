# Security policy

## Reporting a vulnerability

Do not file public GitHub issues for security reports.

Open a GitHub **Security Advisory** against the `lingzhong/agent-readiness-action`
repo (Security tab → Report a vulnerability) to start a private
disclosure thread. You'll receive an acknowledgment within 72 hours.

## Threat model

This Action takes a URL as user input and calls an external scanner API.
The main concerns we design around:

### 1. Scanner endpoint SSRF

`scanner-endpoint` is an action input and defaults to the public
`isitagentready.com` API, but can be overridden. A workflow author who
overrides this to an internal URL is choosing to do so — same trust
level as any other network call from their workflow. We don't
additionally restrict the endpoint. Do not accept `scanner-endpoint`
from untrusted `pull_request_target` inputs.

### 2. Log / annotation injection

The scanner response is user-controllable content from a third party.
Before emitting `::error::` annotations or writing to `$GITHUB_OUTPUT`,
the script escapes `%`, `\r`, and `\n` per GitHub's workflow-command
spec and frames multi-line values in heredoc blocks with a
per-invocation delimiter.

### 3. Output size

The raw `response` output is truncated at ~900 KB to stay under
GitHub's ~1 MB per-output-value limit. A malicious scanner cannot
exhaust output storage.

### 4. No code execution of scanner output

The scanner response is parsed as JSON with `jq` and specific fields
are read by name. No `eval`, no shell interpolation of response
content.

## Supported versions

Pre-1.0: only the latest `v0.1.x` receives security fixes. The floating
tag `v0.1` tracks the latest patch.
