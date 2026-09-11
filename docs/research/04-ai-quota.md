# 04 — AI quota & usage data sources for the RunCat-style menu-bar app (Claude, OpenAI Codex, AWS Bedrock)

Research date: 2026-09-11. Repos cloned (`--depth 20`) into `scratchpad/quota/`:
CodexBar @9f4f544 (2026-09-10), openai/codex @e53c444 (2026-09-11), ccusage @2feea4d (2026-09-11),
ClaudeBar @e3e0798, Claude-Usage-Tracker @588775e, Usage4Claude @49c02da, VibeMeter @07ae1e2, claude-limits @9b47031.

Legend: **[VERIFIED]** = seen in source code, official docs, or directly on this Mac. **[UNVERIFIED]** = inferred, third-party claim, or not checked.
File:line references are relative to `scratchpad/quota/`.

---

## 0. TL;DR

| Provider / user type | Best "remaining capacity" source | Best "usage/spend" source | Risk |
|---|---|---|---|
| **Claude Pro/Max (Claude Code)** | (a) **Claude Code status-line bridge**: documented `rate_limits.five_hour/seven_day` JSON pushed to a script. (b) Opt-in fallback: undocumented `GET https://api.anthropic.com/api/oauth/usage` with Claude Code's OAuth token. | Local `~/.claude/projects/**/*.jsonl` token logs, using ccusage-style 5h blocks and a price table | (a) none. (b) High ToS risk under Anthropic's credential rules. |
| **Anthropic API key (org)** | Rate Limits API (configured limits) plus Usage API `1m` buckets (approximate %) | Admin Usage & Cost API | Low (official). Needs an admin key. |
| **ChatGPT-plan Codex** | `codex app-server` JSON-RPC `account/rateLimits/read` | `~/.codex/sessions/**/*.jsonl` `token_count` events (they also carry `rate_limits`) | Low–medium: the RPC is open source; the backend `wham/usage` behind it is undocumented. |
| **OpenAI API key** | none passive (the `x-ratelimit-*` headers only come back on inference calls) | Admin Usage + Costs API | Low (official). |
| **AWS Bedrock** | CloudWatch `EstimatedTPMQuotaUsage` (1-min) divided by the Service Quotas TPM value | CloudWatch token metrics × price table for "today (est.)", plus Cost Explorer month-to-date (≤24 h lag, $0.01 per request) | Low (official). IAM permissions and SSO session handling needed. |

**Distribution:** ship **outside the Mac App Store (Developer ID + notarization + hardened runtime, not sandboxed)**. Every full-featured prior-art app does this (CodexBar, Claude-Usage-Tracker, VibeMeter). A sandboxed Mac App Store "Lite" build is possible only with API keys, the status-line bridge through an App Group container, and user-granted security-scoped bookmarks (§7).

---

## 1. Provider × data-source matrix

### 1.1 Claude (subscription: Pro/Max/Team/Enterprise via Claude Code)

| # | Source | What it gives | Auth needed | Official? | Freshness | Sandbox-compatible? | Risk |
|---|---|---|---|---|---|---|---|
| C1 | **Status-line JSON** (`rate_limits` on stdin of the user's `statusLine` command) | `five_hour`/`seven_day` `used_percentage` (0–100) and `resets_at` (epoch s). Also `spend_limit` behind a Claude apps gateway. | None. Claude Code pushes it to the script. | **Documented** [VERIFIED code.claude.com/docs/en/statusline] | Real-time while a Claude Code session is active, and only after its first API response. Stale when no session is running. | Yes, if the script writes into an App Group container. The user must edit `~/.claude/settings.json` (or the app offers copy-paste). | None |
| C2 | `GET https://api.anthropic.com/api/oauth/usage` (header `anthropic-beta: oauth-2025-04-20`) | `five_hour`, `seven_day`, `seven_day_opus`, `seven_day_sonnet`, `seven_day_oauth_apps`, `extra_usage`, and a newer `limits[]` array (utilization plus ISO-8601 `resets_at`) | Claude Code OAuth access token from Keychain item `Claude Code-credentials`. Needs the `user:profile` scope. | **Undocumented.** It is the same endpoint Claude Code's `/usage` calls [VERIFIED in the Claude Code binary]. | On demand. Returns HTTP 429 if polled too often [VERIFIED CodexBar rate-limit gate]. | Hard: reading another app's Keychain item from the sandbox [UNVERIFIED] | **High ToS risk** (§2.5). Token refresh can disrupt the CLI. |
| C3 | Local transcripts `~/.claude/projects/**/*.jsonl` (also `$CLAUDE_CONFIG_DIR/projects`, `~/.config/claude/projects`) | Per-message `usage` (input, output, cache_creation, cache_read, 5m/1h cache split), model, timestamp, requestId, message.id. Also `"Claude AI usage limit reached\|<epoch>"` error lines. | File read | Undocumented format; widely parsed (ccusage, CodexBar, VibeMeter) | Near real-time (appended per message) | Needs a temporary-exception entitlement or a user-selected bookmark | Low. Gives tokens and cost, **not** % of plan (Anthropic does not publish token limits). |
| C4 | `claude /usage` in a PTY (screen-scrape) | Same % values as C2, as rendered text | Spawns the user's `claude` | Official UI, but scraping is fragile | Slow (seconds); creates session artifacts | No (child process inherits the sandbox) [UNVERIFIED] | Medium (breaks on UI changes) |
| C5 | claude.ai web API with a `sessionKey` cookie (`/api/organizations/{org}/usage`) | Session, weekly, and Opus % | Browser cookie import or in-app login | Undocumented | On demand; Cloudflare challenges | ClaUse Bar (Mac App Store) does it via in-app login | **High ToS risk:** "may not collect, store, or intermediate Claude.ai credentials or session tokens" |
| C6 | 1-token Messages API call with the OAuth token, then read `anthropic-ratelimit-unified-5h-utilization` etc. | 5h/7d utilization, reset, overage status | OAuth token | Undocumented headers | On demand; **consumes quota** | — | **Highest risk.** It is an inference request with subscription credentials from a third-party app. Claude-Usage-Tracker does this. |

### 1.2 Claude (Anthropic API key / Console organization)

| # | Source | What it gives | Auth | Official? | Freshness | Sandbox | Risk |
|---|---|---|---|---|---|---|---|
| A1 | `GET /v1/organizations/usage_report/messages` | Tokens (uncached input, cache create, cache read, output) by model, workspace, key, tier; buckets of `1m` (max 1,440), `1h` (max 168), `1d` (max 31) | **Admin API key** `sk-ant-admin01-…` (or org:admin OAuth or a non-workspace key). Not available for individual accounts. | **Documented** [VERIFIED] | "typically appears within 5 minutes"; "supports polling once per minute" [VERIFIED] | Yes (network only) | Low |
| A2 | `GET /v1/organizations/cost_report` | USD cost per day (decimal strings, cents), by workspace or description. Priority Tier not included. | Admin key | Documented [VERIFIED] | `1d` buckets only; ~5 min lag | Yes | Low |
| A3 | `GET /v1/organizations/rate_limits` (plus a workspace variant) | **Configured** RPM, ITPM, OTPM per model group. No current usage. | Admin key | Documented [VERIFIED] | Static-ish; cache for 24 h | Yes | Low |
| A4 | Response headers `anthropic-ratelimit-{requests,tokens,input-tokens,output-tokens}-{limit,remaining,reset}` | Live token-bucket remaining | Any API key, **but only on the response to a real request** | Documented [VERIFIED] | Real-time | Yes | Costs money and quota. `count_tokens` has **separate, independent** limits, so it does not show Messages limits [VERIFIED docs]. Whether it returns these headers at all is [UNVERIFIED]. |

### 1.3 OpenAI Codex (ChatGPT Plus/Pro/Business/Enterprise sign-in)

| # | Source | What it gives | Auth | Official? | Freshness | Sandbox | Risk |
|---|---|---|---|---|---|---|---|
| X1 | `codex app-server` stdio JSON-RPC: `initialize`, then `account/rateLimits/read`, plus the notification `account/rateLimits/updated` | `primary`/`secondary` windows (`usedPercent` int, `windowDurationMins`, `resetsAt` epoch s), credits, `planType`, `rateLimitReachedType`, spend-control `individualLimit`, extra per-model limits | Codex's own login (`~/.codex/auth.json` or keyring); the CLI refreshes tokens itself | Public protocol in the open-source CLI (Apache-2.0) [VERIFIED] | On demand. Calls `…/backend-api/wham/usage` internally. | No (spawned child inherits the sandbox) [UNVERIFIED] | Low–medium (protocol may churn; generated TS/JSON schema exists) |
| X2 | `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` `event_msg` / `token_count` | `info.total_token_usage` / `last_token_usage` (input, cached_input, cache_write_input, output, reasoning_output, total) plus **`rate_limits`** (`primary.used_percent` float, `window_minutes` 300/10080, `resets_at` epoch s, `plan_type`, credits) | File read | Undocumented file format but open-source struct [VERIFIED] | As of the **last turn** only | Needs an exception or bookmark | Low. Stale between sessions; must check `resets_at < now`. |
| X3 | `GET https://chatgpt.com/backend-api/wham/usage` (`Authorization: Bearer`, `ChatGPT-Account-Id`) | `rate_limit.primary_window`/`secondary_window` {`used_percent`, `reset_at`, `limit_window_seconds`}, `credits`, `plan_type`, `additional_rate_limits[]` | OAuth access token from `auth.json` | **Undocumented backend** (used by the CLI) | On demand | Needs `auth.json` access | Medium: token refresh races with the CLI; ToS unclear |
| X4 | Response headers `x-codex-primary-used-percent`, `-window-minutes`, `-reset-at` (and `x-<limit_id>-…`) and websocket event `codex.rate_limits` | Same as X1 | Only on inference traffic | Undocumented | Real-time during use | — | Not usable passively |
| X5 | `codex` TUI `/status` | "5h limit" / "Weekly limit" rows | — | Official UI | — | — | Scraping; CodexBar keeps it for diagnostics only |
| X6 | chatgpt.com/codex/settings/usage web page | Same plus a credits history | Browser cookies / WKWebView | Official page, scraping is undocumented | — | — | Medium–high |

### 1.4 OpenAI API key

| # | Source | What it gives | Auth | Official? | Freshness | Risk |
|---|---|---|---|---|---|---|
| O1 | `GET https://api.openai.com/v1/organization/usage/completions` (also embeddings, images, …) | `input_tokens`, `output_tokens`, `input_cached_tokens`, `num_model_requests`; `bucket_width` 1m/1h/1d; `group_by` model/project_id/… | **Admin key** (`OPENAI_ADMIN_KEY`) | Documented [VERIFIED cookbook] | Minutes [UNVERIFIED exact] | Low |
| O2 | `GET https://api.openai.com/v1/organization/costs` | `amount.value`, `amount.currency` per bucket | Admin key | Documented [VERIFIED] | Lagged [UNVERIFIED] | Low |
| O3 | `x-ratelimit-limit-/remaining-/reset-{requests,tokens}` | Live limits | Only on real inference responses | Documented [VERIFIED search of developers.openai.com rate-limits] | Real-time | Not passive |

### 1.5 AWS Bedrock

| # | Source | What it gives | Auth / IAM | Official? | Freshness | Cost | Risk |
|---|---|---|---|---|---|---|---|
| B1 | CloudWatch `GetMetricData`, namespace `AWS/Bedrock`, dimension `ModelId` | `Invocations`, `InvocationLatency`, `InvocationClientErrors`, `InvocationServerErrors`, `InvocationThrottles`, `InputTokenCount`, `OutputTokenCount`, `CacheReadInputTokenCount`, `CacheWriteInputTokenCount`, `TimeToFirstToken`, **`EstimatedTPMQuotaUsage`** | `cloudwatch:GetMetricData` (+ `ListMetrics`) | Documented [VERIFIED] | 1-minute aggregation [VERIFIED AWS blog]; a few minutes of ingestion lag [UNVERIFIED] | CloudWatch API pricing [UNVERIFIED: ~$0.01 per 1,000 metrics requested] | Low |
| B2 | Service Quotas `ListServiceQuotas` / `GetServiceQuota` (service code `bedrock` [UNVERIFIED exact code]) | Per-model "Cross-Region InvokeModel tokens per minute for ${model}", "On-demand InvokeModel tokens per minute for ${model}", "Model invocation max tokens per day for ${model}", "InvokeModel requests per minute for ${model}" (RPM only for some models) | `servicequotas:ListServiceQuotas`, `GetServiceQuota` | Documented [VERIFIED quota names] | Static; cache for 24 h | Free [UNVERIFIED] | Low |
| B3 | Cost Explorer `GetCostAndUsage` (endpoint `ce.us-east-1.amazonaws.com`, filter `SERVICE`) | Unblended cost per day or month for Amazon Bedrock | `ce:GetCostAndUsage` | Documented | "refreshes your cost data at least once every 24 hours" [VERIFIED] | **$0.01 per paginated request** [VERIFIED] | Low; lag makes "today" unreliable |
| B4 | AWS Price List `GetProducts` | Per-model $/1M tokens | `pricing:GetProducts` | Documented | Static | Free [UNVERIFIED] | Low (ClaudeBar uses it) |
| B5 | Local Claude Code transcripts when `CLAUDE_CODE_USE_BEDROCK=1` | Tokens per message (Bedrock model IDs) | File read | — | Real-time | — | [UNVERIFIED that usage is identical]. ccusage pricing handles `anthropic.claude-…-v1:0` IDs. |

---

## 2. Claude — details

### 2.1 Subscription limits

- Two documented windows appear in Claude Code: a rolling **5-hour** window and a **7-day** window. [VERIFIED statusline docs]
  > "`rate_limits`: appears only for Claude.ai Pro and Max subscribers, or behind a Claude apps gateway that sets a spend limit for you, and only after the first API response in the session. Each window (`five_hour`, `seven_day`, `spend_limit`) may be independently absent, and Claude Code drops a window once its `resets_at` time passes."
- Model-scoped weekly buckets exist: `seven_day_opus` and `seven_day_sonnet`. Claude Code's own client code enumerates them:
  `if(["five_hour","seven_day","seven_day_opus","seven_day_sonnet"].includes(n)){ … five_hour → +18000 s … seven_day* → +604800 s` [VERIFIED in the installed `claude.exe` bundle v2.1.268].
  The newer `limits[]` array names scoped models via `scope.model.display_name` (e.g. "Fable") [VERIFIED CodexBar `ClaudeOAuthUsageFetcher.swift:278-281`, and the Claude Code bundle maps `.scope.model.display_name` → `{utilization:o.percent,resets_at:o.resets_at}`].
- Anthropic does not publish token counts per plan; the limits are expressed as percentages. [UNVERIFIED: third-party blogs say the counts are intentionally unpublished and "Max 5x/20x" multiples apply.] So a local-log-only approach **cannot compute a true %**. It can only show tokens, cost, and a user-set budget.

### 2.2 How Claude Code fetches `/usage` [VERIFIED, installed binary]

Excerpt (minified) from `~/.nvm/.../@anthropic-ai/claude-code/bin/claude.exe`:

```js
async function yL(e,{atWall:n=!1}={}){return vr(n?"api_usage_fetch_at_wall":"api_usage_fetch",async()=>{
  if(!ht()||!$p())return{};
  let r=n?"/api/oauth/usage?at_wall=1&skip_spend=1":"/api/oauth/usage",o=0,
  d=await t_(async()=>{o++,t(`fetchUtilization: GET ${r} (attempt ${o})`);
    let p=await _t.get(r,{timeout:5000,headers:{"Content-Type":"application/json"},refreshOAuth:!0,credentials:e});
    if(!p.ok)throw Error(`Auth erro…
```

The binary also contains `oauth-2025-04-20` (3×), `user:profile` (9×), and `.credentials.json` (7×). During inference, Claude Code parses the **`anthropic-ratelimit-unified-*`** response headers:
`anthropic-ratelimit-unified-5h-utilization`, `-5h-reset`, `-5h-surpassed-threshold`, `-7d-utilization`, `-7d-reset`, `-7d-surpassed-threshold`, `-status`, `-fallback`, `-overage-status`, `-overage-reset`, `-overage-in-use`, `-grace-status` … [VERIFIED strings]. This is the most likely feed for the status-line `rate_limits` object [UNVERIFIED linkage].

### 2.3 OAuth usage endpoint: request and response shape

Request, as sent by CodexBar (`CodexBar/Sources/CodexBarCore/Providers/Claude/ClaudeOAuth/ClaudeOAuthUsageFetcher.swift:61-93`) [VERIFIED]:

```swift
private static let baseURL = "https://api.anthropic.com"
private static let usagePath = "/api/oauth/usage"
private static let profilePath = "/api/oauth/profile"
private static let betaHeader = "oauth-2025-04-20"
...
request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
request.setValue(Self.betaHeader, forHTTPHeaderField: "anthropic-beta")
request.setValue("claude-code/\(version)", forHTTPHeaderField: "User-Agent")   // via claudeCodeUserAgent()
```

Response model (decoder at `ClaudeOAuthUsageFetcher.swift:268-414`) [VERIFIED keys]:

```swift
struct OAuthUsageResponse: Decodable {
    let fiveHour: OAuthUsageWindow?          // "five_hour"
    let sevenDay: OAuthUsageWindow?          // "seven_day"
    let sevenDayOAuthApps: OAuthUsageWindow? // "seven_day_oauth_apps"
    let sevenDayOpus: OAuthUsageWindow?      // "seven_day_opus"
    let sevenDaySonnet: OAuthUsageWindow?    // "seven_day_sonnet"
    let sevenDayRoutines: OAuthUsageWindow?  // "seven_day_routines" | "seven_day_cowork" | ...
    let extraUsage: OAuthExtraUsage?         // "extra_usage"
    let limits: [OAuthLimitEntry]?           // "limits"
}
struct OAuthUsageWindow: Decodable { let utilization: Double?; let resetsAt: String? /* "resets_at" ISO-8601 */ }
struct OAuthLimitEntry: Decodable { kind, group, percent, resets_at, scope{model{id,display_name}}, is_active }
struct OAuthExtraUsage: Decodable { is_enabled, monthly_limit, used_credits, utilization, currency }
```

Reconstructed example (shape only, values illustrative) [UNVERIFIED as a literal payload]:

```json
{
  "five_hour":  { "utilization": 42.0, "resets_at": "2026-09-11T14:30:00.000Z" },
  "seven_day":  { "utilization": 18.0, "resets_at": "2026-09-15T09:00:00.000Z" },
  "seven_day_opus": { "utilization": 30.0, "resets_at": "2026-09-15T09:00:00.000Z" },
  "seven_day_sonnet": null,
  "extra_usage": { "is_enabled": false, "monthly_limit": null, "used_credits": null, "utilization": null },
  "limits": [ { "kind": "weekly_scoped", "group": "weekly", "percent": 12, "resets_at": "…", "scope": { "model": { "display_name": "Fable" } }, "is_active": true } ]
}
```

CodexBar mapping [VERIFIED `docs/claude.md`]: `five_hour` → session; `seven_day` → weekly (and the primary fallback when `five_hour` is absent); `seven_day_sonnet`/`seven_day_opus`/`limits[].weekly_scoped` → model weekly; `extra_usage` → monthly extra-usage spend. It also states: *"Requires `user:profile` scope (CLI tokens with only `user:inference` cannot call usage)."*

### 2.4 Where Claude Code credentials live (macOS)

- **Keychain generic password, service `Claude Code-credentials`** [VERIFIED on this Mac: `security find-generic-password -s "Claude Code-credentials"` → `class: "genp"`, `"svce"<blob>="Claude Code-credentials"`; also `ClaudeOAuthCredentials.swift:15` `static let claudeKeychainService = "Claude Code-credentials"`].
- Payload JSON is `{"claudeAiOauth": {"accessToken", "refreshToken", "expiresAt": <ms epoch>, "scopes", "subscriptionType", "rateLimitTier"…}, "mcpOAuth": {…}}` [VERIFIED keys `claudeAiOauth`, `refreshToken`, `expiresAt` (ms), `mcpOAuth` in `ClaudeOAuthCredentialModels.swift:94-140`; `subscriptionType`/`rate_limit_tier` per `docs/claude.md`]. On Claude Code 2.1.x the item may contain only `mcpOAuth` [VERIFIED CodexBar docs, issue #1844].
- **File fallback `~/.claude/.credentials.json`** (or `$CLAUDE_CONFIG_DIR/.credentials.json`) [VERIFIED `ClaudeConfigPaths.swift:49,67`]. It is **absent on this Mac** (Keychain is used); it is typically used on Linux or when the Keychain is unavailable [UNVERIFIED].
- Token refresh (what CodexBar does): `POST https://platform.claude.com/v1/oauth/token`, `grant_type=refresh_token`, `client_id=9d1c250a-e61b-44d9-88ed-5944d1962f5e` [VERIFIED `ClaudeOAuthCredentials.swift:26-28,1449-1450`]. **Do not do this in our app.** Refresh-token rotation can invalidate the CLI's stored token [UNVERIFIED]. It also clearly counts as "intermediating" credentials.
- Keychain ACL: Claude Code "periodically rotates its `Claude Code-credentials` Keychain item and can replace the ACL grant" [VERIFIED CodexBar `docs/claude.md`], so a third-party reader gets repeated prompts.

### 2.5 ToS position (Anthropic) [VERIFIED code.claude.com/docs/en/legal-and-compliance]

> "**OAuth authentication** is intended exclusively for purchasers of Claude Free, Pro, Max, Team, and Enterprise subscription plans and is designed to support ordinary use of Claude Code and other native Anthropic applications."
>
> "Anthropic does not permit third-party developers to offer Claude.ai login into their own applications, or to route requests through Free, Pro, or Max plan credentials on behalf of their users. Moreover, developers may not collect, store, or intermediate Claude.ai credentials or session tokens — sign-in to a Claude account must complete through Anthropic's own flow."
>
> "Anthropic reserves the right to take measures to enforce these restrictions and may do so without prior notice."

Press coverage (The Register, 2026-02-20) reports server-side enforcement that returns *"This credential is only authorized for use with Claude Code and cannot be used for other API requests."* [UNVERIFIED wording].
**Assessment:** a local, read-only GET with the user's own token is a gray area. It is not inference and not "on behalf of users", but it does "collect" a Claude.ai credential. The C5 (in-app claude.ai login / sessionKey) and C6 (1-token Messages call) approaches are clearly worse. **Recommendation:** make C1 (status line) the default, C3 (logs) always-on, and C2 an explicit opt-in with a warning, never refreshing tokens.

### 2.6 Status-line bridge (recommended default for Claude subscriptions) [VERIFIED docs]

Documented fields:

| Field | Meaning |
|---|---|
| `rate_limits.five_hour.used_percentage`, `rate_limits.seven_day.used_percentage` | "Percentage of the 5-hour or 7-day rate limit consumed, from 0 to 100" |
| `rate_limits.five_hour.resets_at`, `rate_limits.seven_day.resets_at` | "Unix epoch seconds when the 5-hour or 7-day rate limit window resets" |
| `rate_limits.spend_limit.used_percentage/resets_at` | Claude apps gateway only (v2.1.251+) |

Doc example:

```json
"rate_limits": {
  "five_hour": { "used_percentage": 23.5, "resets_at": 1738425600 },
  "seven_day": { "used_percentage": 41.2, "resets_at": 1738857600 }
}
```

The docs also say the status line re-runs when "A rate-limit window in the data your script last received reaches its `resets_at` time".

Design: ship `gorunner-statusline` (a tiny signed helper or shell script). It reads stdin, writes `{"ts":…, "session_id":…, "rate_limits":…, "cost":…}` atomically to `~/Library/Group Containers/<TEAMID>.gorunner/claude-statusline.json` (or `~/Library/Application Support/Gorunner/`), and then **chains** to the user's previous `statusLine.command` so their status line keeps working. The app watches the file with `DispatchSource.makeFileSystemObjectSource` or FSEvents.
Limitations: no data until the user runs Claude Code; Pro/Max only (not Team/Enterprise per docs wording [VERIFIED wording]); no Opus-specific weekly value.

### 2.7 Local JSONL logs and ccusage

Sample assistant line from this Mac (values of IDs replaced by type) [VERIFIED]:

```json
{"timestamp":"2026-09-11T00:58:23.590Z","type":"assistant","requestId":"string","sessionId":"string","version":"2.1.268",
 "message":{"id":"string","model":"claude-opus-5","usage":{"input_tokens":32,"cache_creation_input_tokens":11040,
 "cache_read_input_tokens":39711,"cache_creation":{"ephemeral_5m_input_tokens":11040,"ephemeral_1h_input_tokens":0},
 "output_tokens":6,"service_tier":"standard","inference_geo":"not_available"}}}
```

Parsing rules:
- Take only `type:"assistant"` lines with `message.usage`.
- **Dedupe by `message.id` + `requestId`**: streaming chunks repeat the id with cumulative usage [VERIFIED CodexBar docs; ccusage `rust/adapters/claude/src/lib.rs:150,213` `usage_dedupe_hash(message_id, request_id, session_id)`].
- Nested `progress` lines can carry `data.message.message.usage` (sub-agents) [VERIFIED ccusage test fixture `main.rs:458`].
- `usage.iterations[]` with `type:"advisor_message"` carry advisor-model usage [VERIFIED fixture `main.rs:350`].
- Limit-hit marker: `isApiErrorMessage:true` and text `"Claude AI usage limit reached|<epoch>"` [VERIFIED `rust/adapters/claude/src/lib.rs:590-614`]:

```rust
if is_api_error_message != Some(true) { return None; }
let marker = b"Claude AI usage limit reached";
let marker_start = memmem::find(line, marker)?;
let timestamp_start = memchr::memchr(b'|', &line[marker_start..])? + marker_start + 1;
... .parse::<i64>() ... TimestampMs::from_unix_seconds(timestamp)
```

**ccusage block algorithm** (MIT, `rust/crates/ccusage/src/blocks.rs:53-103`) [VERIFIED]. The default session length is 5.0 h (`ccusage-cli-parser/src/parser.rs:61`, flag `-n/--session-length`).

```rust
pub fn identify_session_blocks(mut entries: Vec<LoadedEntry>, session_duration_hours: f64) -> Vec<SessionBlock> {
    if entries.is_empty() { return Vec::new(); }
    let session_duration = (session_duration_hours * MILLIS_PER_HOUR as f64) as i64;
    entries.sort_by_key(|entry| entry.timestamp);
    let now = utc_now();
    let mut blocks = Vec::new();
    let mut current_start: Option<TimestampMs> = None;
    let mut current_entries = Vec::new();
    for entry in entries {
        if let Some(start) = current_start {
            let last_time = current_entries.last().map(|entry: &LoadedEntry| entry.timestamp).unwrap_or(start);
            let since_start = entry.timestamp.duration_since(start);
            let since_last = entry.timestamp.duration_since(last_time);
            if since_start > session_duration || since_last > session_duration {
                blocks.push(create_block(start, std::mem::take(&mut current_entries), now, session_duration));
                if since_last > session_duration {
                    blocks.push(create_gap_block(last_time, entry.timestamp, session_duration));
                }
                current_start = Some(floor_to_hour(entry.timestamp));
            }
        } else {
            current_start = Some(floor_to_hour(entry.timestamp));
        }
        current_entries.push(entry);
    }
    if let Some(start) = current_start && !current_entries.is_empty() {
        blocks.push(create_block(start, current_entries, now, session_duration));
    }
    blocks
}
```

What the algorithm does:
- A block starts at the **first message's timestamp floored to the hour**.
- A new block starts when a message is more than 5 h after the block start **or** more than 5 h after the previous message; the latter also emits a gap block.
- `create_block` (`blocks.rs:109-147`): `end = start + duration`, `is_active = now - last_entry < duration && now < end`. It sums tokens and cost and keeps the first `usage_limit_reset_time`.

Burn rate and projection (`blocks.rs:567-601`) [VERIFIED]:

```rust
let duration_minutes = last.duration_since(first) as f64 / MILLIS_PER_MINUTE as f64;   // first→last entry in block
tokens_per_minute: total_tokens / duration_minutes,
tokens_per_minute_for_indicator: (input_tokens + output_tokens) / duration_minutes,   // excludes cache tokens
cost_per_hour: block.cost_usd / duration_minutes * 60.0,
// projection (active block only):
remaining_minutes = round((block.end_time - now) / 60000)
total_tokens = block.total + tokens_per_minute * remaining_minutes
total_cost   = block.cost + (cost_per_hour / 60) * remaining_minutes
```

Cost: `CostMode::{Auto, Calculate, Display}` (`ccusage-cli/src/types.rs:239-244`). Display uses the log's `costUSD`; Calculate uses LiteLLM pricing (bundled at build time, `ccusage-core/build.rs` `litellm-pricing.json.deflate`); Auto prefers `costUSD` when present, else calculates [VERIFIED enum names; Auto semantics UNVERIFIED in code]. `--token-limit max` uses the historical max block as the "limit" [VERIFIED `parse_token_limit`, `blocks.rs:603-608`].
**Caveat:** ccusage's block is a heuristic. The true Anthropic 5-hour window and its reset time come only from C1/C2.

### 2.8 Anthropic API-key users (A1–A4) [VERIFIED platform.claude.com docs]

```bash
curl "https://api.anthropic.com/v1/organizations/usage_report/messages?starting_at=2025-01-01T00:00:00Z&ending_at=2025-01-08T00:00:00Z&group_by[]=model&bucket_width=1d" \
  -H "anthropic-version: 2023-06-01" -H "x-api-key: $ANTHROPIC_ADMIN_KEY"
curl "https://api.anthropic.com/v1/organizations/cost_report?starting_at=2025-01-01T00:00:00Z&ending_at=2025-01-31T00:00:00Z&group_by[]=workspace_id&group_by[]=description" \
  -H "anthropic-version: 2023-06-01" -H "x-api-key: $ANTHROPIC_ADMIN_KEY"
curl "https://api.anthropic.com/v1/organizations/rate_limits?model=claude-opus-5" \
  -H "x-api-key: $ANTHROPIC_ADMIN_KEY" -H "anthropic-version: 2023-06-01"
```

Rate Limits API response excerpt [VERIFIED]:

```json
{ "data": [ { "type": "rate_limit", "group_type": "model_group", "models": ["claude-opus-5"],
    "limits": [ { "type": "requests_per_minute", "value": 4000 },
                { "type": "input_tokens_per_minute", "value": 10000000 },
                { "type": "output_tokens_per_minute", "value": 800000 } ] } ], "next_page": null }
```

Facts from the docs:
- "The Admin API is unavailable for individual accounts."
- "Usage and cost data typically appears within 5 minutes of API request completion".
- "The API supports polling once per minute for sustained use."
- Cost API: "Daily granularity only (`1d`)".
- Rate limiting is a token bucket, and "only uncached input tokens count toward your ITPM" for most models.
- Headers `anthropic-ratelimit-*-remaining` are rounded to the nearest thousand.

Approximate "% ITPM" = max over the last N `1m` buckets of `(uncached_input + cache_creation)` / `input_tokens_per_minute`. It is ~5 min stale and ignores the token bucket's smoothing [design; UNVERIFIED accuracy].
CodexBar's Admin API fetcher uses `group_by[]=description` for cost and `group_by[]=model` for usage [VERIFIED `ClaudeAdminAPIUsageFetcher.swift:27-29,84,100,115-116`].
Claude Enterprise (claude.ai) orgs use the separate **Analytics API** key instead [VERIFIED docs].

---

## 3. OpenAI Codex — details

### 3.1 Plan limits [VERIFIED learn.chatgpt.com/docs/pricing via developers.openai.com/codex/pricing redirect]

- "local messages and cloud chats share your plan's usage allowance, with weekly limits that may also apply".
- Plus: "5-45 messages per five-hour period (GPT-6 Astra) to 250-2,000 (GPT-5.6 Luna)". Pro 5x/20x are multiples; Business is the same as Plus; Enterprise/Edu are flexible.
- Users check with the usage dashboard `https://chatgpt.com/codex/settings/usage` or "`/status`" in the CLI. Credits can be bought after limits are reached.

### 3.2 Rollout JSONL `token_count` events

Live sample from `~/.codex/sessions/2026/09/10/rollout-2026-09-10T15-04-36-….jsonl` [VERIFIED]:

```json
{"timestamp":"2026-09-10T06:13:00.206Z","type":"event_msg","payload":{"type":"token_count",
 "info":{"total_token_usage":{"input_tokens":714261,"cached_input_tokens":564480,"cache_write_input_tokens":0,
   "output_tokens":7889,"reasoning_output_tokens":3868,"total_tokens":722150},"last_token_usage":{…},"model_context_window":…},
 "rate_limits":{"limit_id":"codex","limit_name":null,
   "primary":{"used_percent":13.0,"window_minutes":300,"resets_at":1789038284},
   "secondary":{"used_percent":2.0,"window_minutes":10080,"resets_at":1789484651},
   "credits":{"has_credits":false,"unlimited":false,"balance":"0"},
   "individual_limit":null,"spend_control_reached":null,"plan_type":"plus","rate_limit_reached_type":null}}}
```

Source of truth — `codex/codex-rs/protocol/src/protocol.rs:2338-2412` [VERIFIED]:

```rust
pub struct TokenCountEvent {
    pub info: Option<TokenUsageInfo>,
    pub rate_limits: Option<RateLimitSnapshot>,
}
pub struct RateLimitSnapshot {
    pub limit_id: Option<String>,
    pub limit_name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub normal_model_slug: Option<String>,
    pub primary: Option<RateLimitWindow>,
    pub secondary: Option<RateLimitWindow>,
    pub credits: Option<CreditsSnapshot>,
    pub individual_limit: Option<SpendControlLimitSnapshot>,
    pub spend_control_reached: Option<bool>,
    pub plan_type: Option<crate::account::PlanType>,
    pub rate_limit_reached_type: Option<RateLimitReachedType>,
}
pub struct RateLimitWindow {
    /// Percentage (0-100) of the window that has been consumed.
    pub used_percent: f64,
    /// Rolling window duration, in minutes.
    pub window_minutes: Option<i64>,
    /// Unix timestamp (seconds since epoch) when the window resets.
    pub resets_at: Option<i64>,
}
```

- Persisted to the rollout: `codex-rs/rollout/src/policy.rs:113` — `EventMsg::TokenCount(_) | … => true` [VERIFIED].
- `RateLimitReachedType` values: `rate_limit_reached`, `workspace_owner_credits_depleted`, `workspace_member_credits_depleted`, `workspace_owner_usage_limit_reached`, `workspace_member_usage_limit_reached` (`protocol.rs:2364-2384`) [VERIFIED].
- Older CLI versions wrote `resets_in_seconds` instead of `resets_at` [UNVERIFIED]. Parse both, and the parser should tolerate missing fields.
- Semantics: `primary` = 5 h (`window_minutes: 300`), `secondary` = weekly (`10080`) in the sample. Do not hard-code this; label windows by `window_minutes` [VERIFIED sample].
- Paths: `$CODEX_HOME/sessions/YYYY/MM/DD/*.jsonl` and `$CODEX_HOME/archived_sessions/*.jsonl` [VERIFIED CodexBar `docs/codex.md`; directory confirmed on this Mac]. `turn_context` lines carry the model [VERIFIED CodexBar docs].

### 3.3 `codex app-server` JSON-RPC

- Method registration — `codex-rs/app-server-protocol/src/protocol/common.rs:1300` `GetAccountRateLimits => "account/rateLimits/read"` and `:1974` `AccountRateLimitsUpdated => "account/rateLimits/updated"` [VERIFIED].
- Wire test (`common.rs:3089`): `{"method":"account/rateLimits/read","id":1}`. There is also `account/usage/read` [VERIFIED].
- v2 response types — `app-server-protocol/src/protocol/v2/account.rs:570-719` [VERIFIED]:

```rust
/// Sparse rolling rate-limit update.
/// Clients should merge available values into the most recent `account/rateLimits/read` response
pub struct AccountRateLimitsUpdatedNotification { pub rate_limits: RateLimitSnapshot }

#[serde(rename_all = "camelCase")]
pub struct RateLimitWindow {
    pub used_percent: i32,                 // rounded from core f64
    pub window_duration_mins: Option<i64>,
    pub resets_at: Option<i64>,
}
```

- Handler — `app-server/src/request_processors/account_processor.rs:1129-1150` [VERIFIED]. It requires ChatGPT auth ("chatgpt authentication required to read rate limits"), then builds a `BackendClient` and calls `get_rate_limits_with_reset_credits()`. That call hits `{chatgpt_base_url}/wham/usage` (or `/api/codex/usage`) — `backend-client/src/client/rate_limit_resets.rs:122-128`.
- How CodexBar drives it — `CodexBar/Sources/CodexBarCore/UsageFetcher.swift:882,979-991` [VERIFIED]:

```swift
arguments: [String] = ["-s", "read-only", "-a", "never", "app-server"],
...
method: "initialize", params: ["clientInfo": ["name": clientName, "version": clientVersion]]
...
let message = try await self.request(method: "account/rateLimits/read")
```

- ClaudeBar does the same (`Sources/Infrastructure/Codex/DefaultCodexRPCClient.swift:76-92`: `app-server`, `initialize`, `initialized` notification, `account/rateLimits/read`) [VERIFIED].
- Advantage: the CLI owns token refresh and account selection. Cost: one child process (keep it alive and reuse, or spawn per poll with timeouts). CodexBar escalates SIGTERM→SIGKILL on timeout [VERIFIED docs].

### 3.4 Direct backend `wham/usage` (what CodexBar prefers)

`CodexOAuthUsageFetcher.swift:391-427` [VERIFIED]:

```swift
private static let defaultChatGPTBaseURL = "https://chatgpt.com/backend-api/"
private static let chatGPTUsagePath = "/wham/usage"
private static let codexUsagePath = "/api/codex/usage"
...
request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
if let accountId, !accountId.isEmpty { request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id") }
```

Response fields (`CodexOAuthUsageFetcher.swift:21-32,161-223`) [VERIFIED]:
- `account_id`, `plan_type`, `credits{has_credits,unlimited,balance}`, `individual_limit`, `spend_control.individual_limit`, `additional_rate_limits[]{limit_name, metered_feature, rate_limit}`
- `rate_limit.primary_window` / `rate_limit.secondary_window` → `{ "used_percent": Int, "reset_at": Int, "limit_window_seconds": Int }`

Note the naming differences: backend `reset_at`/`limit_window_seconds`; core `resets_at`/`window_minutes`; app-server `resetsAt`/`windowDurationMins`.
CodexBar honors `chatgpt_base_url` from `~/.codex/config.toml` (`:579-625`) and does **not** write refreshed tokens back to `auth.json` [VERIFIED docs]. Its token refresh uses `https://auth.openai.com/oauth/token`, `client_id app_EMoamEEZ73f0CkXaXp7hrann` (`CodexTokenRefresher.swift:7-8`) [VERIFIED]. Avoid this; prefer X1.

Headers during inference: `x-codex-primary-used-percent`, `x-codex-primary-window-minutes`, `x-codex-primary-reset-at`, and `secondary` equivalents, plus `x-<limit-id>-…` and `…-limit-name` (`codex-api/src/rate_limits.rs:57-100`). Also the websocket event type `"codex.rate_limits"` [VERIFIED].

### 3.5 Codex auth storage

- `~/.codex/auth.json` (or `$CODEX_HOME/auth.json`). Keys on this Mac: `OPENAI_API_KEY`, `auth_mode`, `last_refresh`, `tokens{access_token, account_id, id_token, refresh_token}` [VERIFIED key names only].
- It may live in the OS keyring instead: `cli_auth_credentials_store` = `file` (default) | `keyring` | `auto` | `ephemeral` (`codex-rs/config/src/types.rs:109-119`) [VERIFIED]. With `keyring`, `auth.json` is absent, which is another reason to prefer the app-server route.
- `auth_mode` API key vs ChatGPT: rate limits need ChatGPT auth (`account_processor.rs` check) [VERIFIED]. Codex can also be signed in with an Amazon Bedrock API key (`login/src/auth/bedrock_api_key.rs`) [VERIFIED file exists]; then no ChatGPT limits apply, and Bedrock metrics apply instead.

### 3.6 OpenAI API-key users [VERIFIED developers.openai.com cookbook]

```http
GET https://api.openai.com/v1/organization/usage/completions?start_time=1788998400&bucket_width=1h&group_by=model
Authorization: Bearer $OPENAI_ADMIN_KEY
GET https://api.openai.com/v1/organization/costs?start_time=…&bucket_width=1d
```

- Results carry `input_tokens`, `output_tokens`, `input_cached_tokens`, `num_model_requests`, and (for Costs) `amount.value`/`amount.currency`. Pagination is via `next_page`.
- "The Usage API may not always reconcile perfectly with the Costs" [VERIFIED search snippet of API reference].
- Rate-limit headers: `x-ratelimit-limit-requests`, `x-ratelimit-remaining-requests`, `x-ratelimit-limit-tokens`, `x-ratelimit-remaining-tokens`, `x-ratelimit-reset-requests`, `x-ratelimit-reset-tokens` (durations like `6s`, `1m30s`) [VERIFIED search of rate-limits guide]. These are not passive.

---

## 4. AWS Bedrock — details

### 4.1 CloudWatch metrics [VERIFIED docs.aws.amazon.com/bedrock/latest/userguide/monitoring-runtime-metrics.html]

Namespace `AWS/Bedrock`; dimension `ModelId` (all metrics). Metrics:
- `Invocations`, `InvocationLatency` (ms), `InvocationClientErrors`, `InvocationServerErrors`
- `InvocationThrottles` — "Throttled requests and other invocation errors don't count as either Invocations or Errors"
- `InputTokenCount`, `OutputTokenCount`, `LegacyModelInvocations`, `OutputImageCount`, `TimeToFirstToken`
- `EstimatedTPMQuotaUsage`, `CacheReadInputTokenCount` ("don't count toward your TPM quota"), `CacheWriteInputTokenCount` ("count toward your TPM quota")

`EstimatedTPMQuotaUsage` caveat (verbatim): *"This metric is an approximation and does not reflect the reservation-based token consumption that drives throttling decisions. Throttling is based on the upfront reservation of input tokens plus `max_tokens` … Do not use this metric as the sole indicator for quota use or capacity planning."*
The AWS blog (2026-03) adds optional dimensions `ServiceTier`, `ResolvedServiceTier`, `ContextWindow`, and "1-minute aggregation … no additional cost … no opt-in" [VERIFIED].

### 4.2 Quotas and "% of quota used"

Burndown [VERIFIED quotas-token-burndown.html]:
- Request start deducts `Total input tokens + max_tokens`. Request end settles to `InputTokenCount + CacheWriteInputTokenCount + (OutputTokenCount x burndown rate)`.
- Burndown is **15×** output for Claude 4.8, **10×** for Claude Sonnet 5 / Opus 5 / Fable 5.1, and **5×** for other Anthropic models ≤4.7.
- Tokens-per-day default = TPM × 24 × 60.

Quota names [VERIFIED quotas-runtime.html]:
- `Cross-Region InvokeModel tokens per minute for ${model}`
- `On-demand InvokeModel tokens per minute for ${model}`
- `Model invocation max tokens per day for ${model}`
- `InvokeModel requests per minute for ${model}` — not all models; "Anthropic Claude Opus 4.7 and Claude Opus 4.8 – do not have an RPM quota"

The quotas apply to every inference API on `bedrock-runtime`. `bedrock-mantle` has separate input- and output-TPM quotas, and Service Quotas exposed those per model in May 2026 [VERIFIED what's-new].

Computation (design):

```
quotaTPM   = ServiceQuotas.ListServiceQuotas(ServiceCode: "bedrock")   // cache 24h
             .first { $0.QuotaName matches (modelId has "us."/"eu."/"apac."/"global." prefix
                                           ? "Cross-Region InvokeModel tokens per minute for <Model Name>"
                                           : "On-demand InvokeModel tokens per minute for <Model Name>") }.Value
usedTPM(t) = Sum(EstimatedTPMQuotaUsage, ModelId=<id>, Period=60) at minute t
             // fallback if metric missing: Sum(InputTokenCount) + Sum(CacheWriteInputTokenCount) + burndown * Sum(OutputTokenCount)
tpmPct     = max(usedTPM over last 5 complete minutes) / quotaTPM
throttled  = Sum(InvocationThrottles, last 15 min) > 0   → show a warning badge
```

Mapping CloudWatch `ModelId` values (e.g. `us.anthropic.claude-opus-5`, application inference profile ARNs) to Service Quotas' human model names needs a lookup table or fuzzy matching [UNVERIFIED exact ModelId dimension values for inference profiles; verify with `ListMetrics`]. Quota codes (`L-…`) are not published in the docs I read [UNVERIFIED], so match by name.

`GetMetricData` request (JSON protocol, as CodexBar signs it by hand: `X-Amz-Target: GraniteServiceVersion20100801.GetMetricData`, `Content-Type: application/x-amz-json-1.0`, SigV4 service `monitoring`) [VERIFIED `BedrockCloudWatchUsage.swift:133-145`]:

```json
{
  "StartTime": 1789100000, "EndTime": 1789100900, "ScanBy": "TimestampDescending",
  "MetricDataQueries": [
    { "Id": "quota", "MetricStat": { "Metric": { "Namespace": "AWS/Bedrock", "MetricName": "EstimatedTPMQuotaUsage",
        "Dimensions": [ { "Name": "ModelId", "Value": "us.anthropic.claude-opus-5" } ] }, "Period": 60, "Stat": "Sum" } },
    { "Id": "thr", "MetricStat": { "Metric": { "Namespace": "AWS/Bedrock", "MetricName": "InvocationThrottles",
        "Dimensions": [ { "Name": "ModelId", "Value": "us.anthropic.claude-opus-5" } ] }, "Period": 60, "Stat": "Sum" } },
    { "Id": "inTok", "Expression": "SUM(SEARCH('{AWS/Bedrock,ModelId} MetricName=\"InputTokenCount\"', 'Sum', 86400))" }
  ]
}
```

CodexBar's aggregate query — `BedrockCloudWatchUsage.swift:113-128` [VERIFIED]:

```swift
let search = "SEARCH('{AWS/Bedrock,ModelId} " + "MetricName=\"\(metric.cloudWatchName)\" claude', 'Sum', 86400)"
return ["Id": metric.rawValue, "Expression": "SUM(\(search))", "ReturnData": true]
```

It uses a 14-day lookback over `InputTokenCount`, `OutputTokenCount`, and `Invocations`, filtered to Claude. ClaudeBar uses `import AWSCloudWatch`, `ListMetrics(namespace: "AWS/Bedrock")`, and per-model `InputTokenCount`/`OutputTokenCount`, with cost estimated via the AWS **Price List** API (`BedrockPricingService.swift`, `output.priceList`) [VERIFIED].

### 4.3 Cost Explorer [VERIFIED]

- "Each paginated API request incurs a charge of $0.01."
- "Cost Explorer refreshes your cost data at least once every 24 hours … some data might be updated later than 24 hours."
- Endpoint: CodexBar signs `https://ce.us-east-1.amazonaws.com`, target `AWSInsightsIndexService.GetCostAndUsage`, body `{"TimePeriod":{Start,End},"Granularity":…,"Metrics":["UnblendedCost"],"GroupBy":[{"Type":"DIMENSION","Key":"SERVICE"}]}` (`BedrockUsageStats.swift:233-270`) [VERIFIED].

Better for a menu-bar app is `Filter: {"Dimensions":{"Key":"SERVICE","Values":["Amazon Bedrock"]}}` with `Granularity: DAILY` [UNVERIFIED exact SERVICE value string; Anthropic models bought via Marketplace may appear under a different service name]. Poll ≤ every 6 h: 4/day × 30 = 120 requests ≈ **$1.20/month**. "Today" should come from CloudWatch tokens × price, labeled "est."

### 4.4 Auth on a Mac and the Swift SDK

- `~/.aws/config` / `~/.aws/credentials` profiles, SSO (`sso_session`, `sso_start_url`, `sso_region`; token cache `~/.aws/sso/cache/*.json`), `credential_process`, assume-role. Claude Code itself uses the default chain, `AWS_PROFILE`, and `awsAuthRefresh: "aws sso login --profile …"` [VERIFIED code.claude.com/docs/en/amazon-bedrock].
- **aws-sdk-swift** latest release **1.7.81 (2026-09-10)** [VERIFIED GitHub API]. Products present in `Package.swift`: `AWSCloudWatch`, `AWSServiceQuotas`, `AWSCostExplorer`, `AWSSTS`, `AWSSSO`, `AWSSSOOIDC`, `AWSSDKIdentity`, `AWSClientRuntime`, `AWSBedrock`, `AWSBedrockRuntime` [VERIFIED]. The SDK's SSO token-provider support is documented; whether the default chain handles `credential_process` is [UNVERIFIED].
- Alternative (CodexBar): no SDK. Shell out `aws configure export-credentials --profile <p> --format process` and do SigV4 by hand (`BedrockProfileCredentialProvider.swift:33-35`, `BedrockAWSSigner.swift`) [VERIFIED]. That covers SSO, assume-role, credential_process, and MFA-cached profiles, and maps "sso login"/"expired" stderr to `profileSessionExpired`. Trade-off: it depends on AWS CLI v2 and a subprocess, but the binary stays tiny. The SDK adds a large dependency tree [UNVERIFIED size].
- Minimal IAM policy for the app: `cloudwatch:GetMetricData`, `cloudwatch:ListMetrics`, `servicequotas:ListServiceQuotas`, `servicequotas:GetServiceQuota`, `ce:GetCostAndUsage` (optional), `pricing:GetProducts` (optional).
- **Sandbox:** reading `~/.aws` needs `com.apple.security.temporary-exception.files.home-relative-path.read-only` with `/.aws/` (App Review discretion) [VERIFIED entitlement exists; acceptance UNVERIFIED]. A spawned `aws` CLI inherits the sandbox [UNVERIFIED]. In-app SSO device-authorization via `AWSSSOOIDC` avoids file access [design].

### 4.5 Claude Code on Bedrock

- Enabled by `CLAUDE_CODE_USE_BEDROCK=1` (plus `AWS_REGION`, `AWS_PROFILE`, `AWS_BEARER_TOKEN_BEDROCK`, `ANTHROPIC_DEFAULT_*_MODEL=us.anthropic.…`). Also Mantle via `CLAUDE_CODE_USE_MANTLE=1` [VERIFIED docs].
- The status-line `rate_limits` object is **not** provided (it is Pro/Max/gateway only) [VERIFIED doc wording]. The OAuth usage endpoint does not apply.
- Local transcripts are still written under `~/.claude/projects` with `message.usage` [UNVERIFIED for Bedrock specifically; the transcript format is provider-agnostic in practice]. ccusage's pricing table contains Bedrock IDs (`anthropic.claude-opus-4-8`, `…-v1:0`, `claude-sonnet-4-20250514-via-bedrock`) (`ccusage-core/src/pricing.rs:4302-5010`) [VERIFIED], which suggests Bedrock model strings do show up in logs.
- AWS reference: `aws-solutions-library-samples/guidance-for-claude-code-with-amazon-bedrock` has a MONITORING.md (OTel-based) [VERIFIED link exists].

---

## 5. Prior art (open-source macOS menu-bar apps)

| App | URL | License | Claude source | Codex source | Bedrock | Refresh | Auth handling | Sandbox |
|---|---|---|---|---|---|---|---|---|
| **CodexBar** (steipete) | github.com/steipete/CodexBar | MIT [VERIFIED] | App order: **OAuth API** (`/api/oauth/usage`) → **CLI PTY** (`claude` + `/usage`) → **Web API** (claude.ai `sessionKey` cookie from Safari/Chrome/Firefox). Admin API when an `sk-ant-admin` key is set. Local JSONL cost scan. | **OAuth `wham/usage`** from `auth.json` → **`codex app-server`** `account/rateLimits/read` → optional chatgpt.com WKWebView scrape. Local rollout cost scan. | Cost Explorer MTD plus CloudWatch 14-day Claude tokens (hand-rolled SigV4); keys or `aws configure export-credentials` | Manual, 1, 2, 5, 15, 30 min, Adaptive, Adaptive+agent-aware (`SettingsStore.swift:9-37`) [VERIFIED]; local cost scans ≥15 min | Claude Keychain read is opt-in with a prompt policy; OAuth cache in own Keychain; never writes `auth.json`; 429 gate on Claude usage | Not sandboxed (Developer ID) [UNVERIFIED entitlement file not checked; reads browser cookies so cannot be sandboxed] |
| **ClaudeBar** (tddworks) | github.com/tddworks/ClaudeBar | MIT (README) [VERIFIED] | `ClaudeAPIUsageProbe`: `https://api.anthropic.com/api/oauth/usage` with creds "from `~/.claude/.credentials.json` or Keychain"; **refreshes** via `https://platform.claude.com/v1/oauth/token`; fallback "Runs `claude /usage`" [VERIFIED `ClaudeAPIUsageProbe.swift:119-150`, `ClaudeConfigCard.swift:150`] | `codex app-server` JSON-RPC (default) or `wham/usage` [VERIFIED `DefaultCodexRPCClient.swift:76-92`] | **AWSCloudWatch SDK** `ListMetrics`/`InputTokenCount`/`OutputTokenCount` per model plus **AWS Price List** for cost; SSO profile or env [VERIFIED] | off, 1, 5, 10, 15 min (`RefreshInterval.swift:10-26`) [VERIFIED] | Reads foreign creds; in-memory TTL cache | [UNVERIFIED] |
| **Claude-Usage-Tracker** (hamed-elfayome) | github.com/hamed-elfayome/Claude-Usage-Tracker | MIT [VERIFIED] | claude.ai web API with `sessionKey` cookie; for CLI OAuth it says the usage endpoint "is disabled" and instead sends a **1-token Haiku Messages call** and reads headers (`ClaudeAPIService.swift:544-568`) [VERIFIED] | `wham/usage` / `api/codex/usage` with `ChatGPT-Account-Id` (`CodexAPIService.swift:23-90`) [VERIFIED] | — | per-profile, default 30 s (`MenuBarManager.swift:738`) [VERIFIED] | Stores the session key per profile | `app-sandbox` **false** [VERIFIED] |
| **Usage4Claude** (f-is-h) | github.com/f-is-h/Usage4Claude | MIT [VERIFIED] | Own **PKCE OAuth** against Claude (`ClaudeOAuthCoordinator.swift:114-118`) plus claude.ai `api/organizations/{orgId}/usage` [VERIFIED] | Own PKCE OAuth for Codex, then `wham/usage` [VERIFIED] | — | default 180 s (`UserSettings.swift:890`) [VERIFIED] | In-app login (**conflicts with Anthropic's "may not offer Claude.ai login"**) | `app-sandbox` **true** [VERIFIED] |
| **VibeMeter** (steipete) | github.com/steipete/VibeMeter | MIT [VERIFIED] | **Local logs** `~/.claude/projects/**.jsonl` via a **security-scoped bookmark from NSOpenPanel** (`ClaudeLogBookmarkManager.swift`); 5 h window = entries in the last 5 h (`ClaudeFiveHourWindowCalculator.swift:17-22`); Tiktoken counting [VERIFIED] | — | — | [UNVERIFIED] | Cursor/OpenAI via web login | `app-sandbox` **false** [VERIFIED] |
| **claude-limits** (figueiredouc) | github.com/figueiredouc/claude-limits | MIT [VERIFIED] | Python `rumps`: `GET https://api.anthropic.com/api/oauth/usage` with the token from Keychain `Claude Code-credentials`; "Does **not** refresh the token. If it expires, the bar shows `⚠ re-auth`" [VERIFIED README] | — | — | [UNVERIFIED] | Read-only, in-memory token | n/a (Python) |
| ccusage (ryoppippi) | github.com/ryoppippi/ccusage | MIT [VERIFIED] | CLI (not a menu bar): local JSONL, blocks, `--live` | Codex adapter in the monorepo [UNVERIFIED details] | — | — | — | — |
| vibepulse (kenn-io) | github.com/kenn-io/vibepulse | [UNVERIFIED] | Menu bar wrapping **ccusage** for Claude Code and Codex token consumption [VERIFIED search description] | via ccusage | — | — | — | — |
| tokscale (junhoyeo) | github.com/junhoyeo/tokscale | [UNVERIFIED] | Rust CLI/TUI parsing local logs of many agents (Claude Code, Codex, Gemini, Cursor…), plus a leaderboard [VERIFIED search description] | local logs | — | — | uploads to leaderboard optionally [UNVERIFIED] | — |
| ClaUse Bar (Mac App Store) | apps.apple.com/app/id6759294136 | proprietary | Claude "one-time code" login; "stores only the session token in macOS Keychain"; sandboxed [VERIFIED store text] | — | — | — | Session token (ToS-sensitive) | **Sandboxed (MAS)** |

Other search hits (not analyzed): `JBotwina/token-usage`, `matejrondzik/claude-usage-widget`, `eddmann/ClaudeMeter`, Claude Monitor (yuris5n), claudeusagebar.com, `aws-samples/sample-quota-dashboard-for-amazon-bedrock` (CloudWatch dashboard with custom TPM/RPM-vs-quota metrics — a useful reference for the Bedrock % math), `awslabs/bedrock-usage-analyzer`.

**Takeaways from prior art**
1. Every Swift app that shows real Claude % uses the undocumented OAuth usage endpoint, claude.ai cookies, or header probing. None uses the documented status-line feed.
2. For Codex, `codex app-server` → `account/rateLimits/read` is the cleanest (ClaudeBar's default). CodexBar prefers direct `wham/usage` for speed.
3. Bedrock prior art covers spend and tokens only. **No app computes TPM % of Service Quota.** That is a differentiator.
4. Refresh intervals cluster at 1–5 min for quotas and ≥15 min for log/cost scans. Keychain-prompt hygiene and 429 backoff are recurring pain points (CodexBar `docs/keychain-prompts.md`).

---

## 6. Recommended provider plugin architecture (Swift)

### 6.1 Core types

```swift
public enum ProviderID: String, Codable, Sendable { case claude, anthropicAPI, codex, openAIAPI, bedrock }

public enum SourceKind: String, Codable, Sendable {
    case claudeStatusLine, claudeOAuthUsage, claudeLocalLogs, anthropicAdminAPI
    case codexAppServer, codexRolloutLogs, openAIAdminAPI
    case bedrockCloudWatch, bedrockServiceQuotas, bedrockCostExplorer
}

public enum Trust: Sendable { case official, openSourceInterface, undocumented, heuristic }

public struct QuotaWindow: Codable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable { case session5h, weekly, modelWeekly, monthlySpend, tpm, rpm, itpm, otpm, budget }
    public let id: String                 // "claude.five_hour", "codex.secondary", "bedrock.tpm.us.anthropic.claude-opus-5"
    public let kind: Kind
    public let label: String              // "5h", "Weekly", "Opus weekly", "TPM"
    public let usedFraction: Double       // 0...1 (clamped); show ">100%" separately if over
    public let resetsAt: Date?
    public let windowDuration: TimeInterval?
    public let detail: String?            // "Claude Opus 5", "Plus", …
}

public struct SpendLine: Codable, Sendable { let label: String; let amount: Decimal; let currency: String; let isEstimate: Bool; let period: DateInterval }
public struct TokenSummary: Codable, Sendable { let input, output, cacheRead, cacheWrite: Int; let period: DateInterval; let burnRatePerMin: Double? }

public struct UsageSnapshot: Codable, Sendable {
    public let provider: ProviderID
    public let source: SourceKind
    public let trust: Trust
    public var windows: [QuotaWindow]
    public var spend: [SpendLine]
    public var tokens: TokenSummary?
    public let fetchedAt: Date            // when we fetched
    public let dataAsOf: Date             // when the provider's data was true (rollout event ts, CloudWatch minute…)
    public var account: String?           // redacted email / plan, never secrets
}

public enum ProviderError: Error, Sendable, Equatable {
    case notConfigured                    // hide provider or show "Set up…"
    case authMissing(hint: String)        // "Run `codex login`"
    case authExpired(hint: String)        // "Run `claude` once" / "aws sso login --profile work"
    case permissionDenied(missing: [String]) // IAM actions, Keychain denied, file access denied
    case rateLimited(retryAt: Date?)
    case network(String)
    case toolNotFound(String)             // codex / aws binary
    case schemaChanged(String)            // decoding failed → keep last good, flag
    case noRecentData                     // e.g. no Claude Code session since window reset
}

public protocol UsageSource: Sendable {
    var kind: SourceKind { get }
    var trust: Trust { get }
    var cadence: RefreshCadence { get }
    func isAvailable(_ env: ProviderEnvironment) async -> Bool
    func fetch(_ ctx: FetchContext) async throws -> UsageSnapshot
    /// Optional push stream (file watchers, app-server notifications)
    func updates(_ ctx: FetchContext) -> AsyncStream<UsageSnapshot>?
}

public protocol UsageProvider: Sendable {
    var id: ProviderID { get }
    var displayName: String { get }
    /// Ordered by preference; the coordinator merges windows (first non-stale wins per window id)
    func sources(settings: ProviderSettings) -> [any UsageSource]
}

public struct RefreshCadence: Sendable {
    let base: Duration; let min: Duration; let jitter: Double
    let backoff: (attempt: Int) -> Duration   // exponential, capped
    let onMenuOpen: Bool
}
```

### 6.2 Coordinator, caching, and state

- `actor UsageCoordinator`:
  - Runs one task per enabled source.
  - Merges the snapshots into a per-provider `ProviderState`:

    ```swift
    enum ProviderState { case disabled, setupNeeded(ProviderError), loading, ok(UsageSnapshot), stale(UsageSnapshot, ProviderError) }
    ```

  - Publishes to SwiftUI via `@Observable` on the main actor.
- Merge rule: per `QuotaWindow.id`, prefer the highest `trust` whose `dataAsOf` is newer than the window's last reset. Drop a window if `resetsAt < now` (Claude Code does the same) and show "reset — no new data".
- Last-good cache: `~/Library/Application Support/Gorunner/snapshots/<provider>.json` (no secrets), restored at launch and marked stale with age ("3 h ago"), as CodexBar does with `history/claude.json`.
- Incremental log parsing: keep `(inode, size, offset)` per JSONL file in `~/Library/Caches/Gorunner/logs.sqlite`, append-only reads, debounced FSEvents (5–10 s). Dedupe Claude rows by `message.id + requestId`.
- Scheduling:
  - Pause on `NSWorkspace.willSleepNotification` and resume on wake with an immediate fetch.
  - Stretch intervals ×2 in Low Power Mode (`ProcessInfo.isLowPowerModeEnabled`).
  - Refresh on menu open when the last fetch is older than 60 s.
- Notifications at 50/80/90% per window, re-armed on reset (the claude-limits pattern).

### 6.3 Per-provider source chains and cadence

| Provider | Source (priority) | Cadence | Notes |
|---|---|---|---|
| Claude (subscription) | 1. `claudeStatusLine` (file watch) | push | Needs a one-time "Install status-line bridge" that chains the existing command |
| | 2. `claudeOAuthUsage` (**opt-in**, off by default, ToS warning) | 5 min, min 2 min; honor `Retry-After`; ≥15 min after a 429 | Read Keychain `Claude Code-credentials` per fetch; never persist, never refresh; if `expiresAt` passed → `authExpired("Run claude")` |
| | 3. `claudeLocalLogs` | FSEvents plus a 60 s debounce | Tokens today, ccusage block (start, elapsed, burn rate), est. $ via price table; `usage limit reached\|epoch` → reset time |
| Anthropic API | `anthropicAdminAPI` usage `1m` + `cost_report` `1d` + `rate_limits` (24 h) | 5 min (usage), 30 min (cost) | Admin key in our Keychain |
| Codex (ChatGPT) | 1. `codexAppServer` (`codex -s read-only -a never app-server`, keep-alive ≤10 min idle) | 3 min, min 1 min; also subscribe to `account/rateLimits/updated` | Timeouts: init 15 s, request 10 s; SIGTERM→SIGKILL |
| | 2. `codexRolloutLogs` (newest `token_count` with `rate_limits`) | FSEvents | Works offline or without the CLI on PATH; stale if `resets_at < now` |
| OpenAI API | `openAIAdminAPI` completions usage `1h` + costs `1d` | 15 min | Admin key in Keychain |
| Bedrock | `bedrockCloudWatch` (EstimatedTPMQuotaUsage, InvocationThrottles, tokens per model; 15 min lookback, Period 60) | 2 min (only while there were invocations in the last hour; else 15 min) | Discover model IDs with `ListMetrics` every 6 h |
| | `bedrockServiceQuotas` | 24 h | Match by quota name |
| | `bedrockCostExplorer` (**opt-in**, shows "$0.01/request") | 6 h | MTD only; "today" = CloudWatch tokens × price (est.) |

### 6.4 Secrets and Keychain

- Our own secrets (Anthropic admin key, OpenAI admin key, optional static AWS keys): generic-password items, service `com.<org>.gorunner.credentials`, account `<provider>.<label>`, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, no iCloud sync. Load lazily; hold in memory only for the request.
- Foreign credentials (Claude Code Keychain item, `~/.codex/auth.json`, `~/.aws`) are never copied into our Keychain or disk. Read at use and zeroize references after the request. Treat a denied Keychain prompt as `permissionDenied` and back off for 24 h unless the user clicks "Retry" (CodexBar's lesson on prompt storms).
- AWS: resolve credentials per fetch (SDK default chain with profile name, or `aws configure export-credentials`). Cache temporary creds in memory until `Expiration - 5 min` (Claude Code does the same).
- Stable Developer ID signing keeps Keychain "Always Allow" grants durable across updates [VERIFIED CodexBar keychain doc].

### 6.5 Menu rendering (examples)

```
Claude  (Max · via Claude Code)          ●
  5h      42% · resets 14:30              ▓▓▓▓░░░░░░
  Weekly  18% · resets Mon 09:00          ▓▓░░░░░░░░
  Opus wk 30%
  Today   1.9M tok · ~$14.20 est · 320 tok/min
Codex   (Plus)
  5h      13% · resets 16:44
  Weekly   2% · resets Tue 11:04
Bedrock (work · us-east-1)
  Opus 5  TPM 12% · 0 throttles (15m)
  Spend   $3.21 today (est.) · $88.40 MTD
Anthropic API (org)  ·  OpenAI API (org)
  $41.10 MTD · 12.3M tok today
—
Updated 1m ago · Refresh ⌘R · Settings…
```

Format rules:
- `"5h \(pct)% · resets \(timeFormatter(resetsAt))"`, using the day name when the reset is more than 24 h away.
- Stale entries show "· 2h old" in secondary color.
- Errors show one line with a fix action ("Run `aws sso login --profile work`", "Enable status-line bridge…").
- Optional RunCat tie-in: animation speed = max(CPU%, highest AI window %) when "AI mode" is on.

---

## 7. Mac App Store vs Developer ID

| Capability | Sandboxed (Mac App Store) | Developer ID (notarized, hardened runtime, not sandboxed) |
|---|---|---|
| Read `~/.claude/projects`, `~/.codex/sessions`, `~/.aws` | Requires `com.apple.security.temporary-exception.files.home-relative-path.read-only` (`/.claude/`, `/.codex/`, `/.aws/`) — "Only App Review can give you a definitive answer" [VERIFIED Apple forum/doc]. Or a user-picked **security-scoped bookmark** via NSOpenPanel (VibeMeter pattern) [VERIFIED VibeMeter code]; hidden folders are awkward for users. | Direct read |
| Read Claude Code's Keychain item | Very likely impossible or unreliable [UNVERIFIED] | Works with a user prompt ("Always Allow") [VERIFIED CodexBar] |
| Spawn `codex app-server`, `aws`, `claude` | Child inherits the sandbox and cannot read their own dotfiles [UNVERIFIED] | Works |
| Status-line bridge | Works if the script writes to the **App Group container** (the app reads its own container); the user must add the `statusLine` config manually [design] | Works; the app can offer to edit `~/.claude/settings.json` with consent |
| Admin APIs (Anthropic/OpenAI), Bedrock with static keys or in-app SSO OIDC | Works (`com.apple.security.network.client`) | Works |
| Updates | App Store | Sparkle (EdDSA-signed appcast; CodexBar ships `appcast.xml`) |
| Distribution and trust | Discovery, review, sandbox trust | DMG/Homebrew cask, notarization ticket |
| Prior-art precedent | Usage4Claude and ClaUse Bar are sandboxed **because** they log in to Claude themselves (ToS-conflicting) | CodexBar, Claude-Usage-Tracker, VibeMeter (non-sandboxed) |

**Recommendation:** primary build = **Developer ID + notarization + hardened runtime, sandbox off**, auto-update via Sparkle, Homebrew cask. The core value (Codex app-server or rollout logs, Claude logs, `~/.aws` profiles and SSO, the CLI-owned credentials) needs dotfile access and subprocesses that the Mac App Store will likely not permit. If a Mac App Store presence matters, ship a separate "Lite" target sharing the same `UsageProvider` package, limited to: Admin-API providers, Bedrock with keys or in-app SSO, the status-line bridge through the App Group, and bookmark-granted log folders. No Claude Keychain access, no subprocesses.

---

## 8. Open questions / to verify during implementation

1. Exact `/api/oauth/usage` JSON for a live Max account (null vs absent windows, `limits[]` population) — capture with the user's consent. [UNVERIFIED]
2. Whether Anthropic's server-side enforcement blocks non-Claude-Code User-Agents on `/api/oauth/usage` (CodexBar spoofs `claude-code/<version>`). [UNVERIFIED]
3. Status-line `rate_limits` on Team/Enterprise seats (the docs say Pro and Max only). [UNVERIFIED]
4. Codex rollout backward compatibility (`resets_in_seconds` in older files). [UNVERIFIED]
5. Service Quotas code for Bedrock (`bedrock`), exact quota names for Claude 5-series models, and the `ModelId` dimension value for cross-region profiles and application inference profile ARNs. [UNVERIFIED]
6. Cost Explorer `SERVICE` value for Anthropic-on-Bedrock (Marketplace vs "Amazon Bedrock"). [UNVERIFIED]
7. Sandbox behavior of spawned CLIs and foreign Keychain items (build a spike). [UNVERIFIED]
8. aws-sdk-swift default chain support for `credential_process` and `sso_session`; binary-size impact vs hand-rolled SigV4. [UNVERIFIED]

---

## Sources

- Claude Code docs: [Status line](https://code.claude.com/docs/en/statusline), [Legal and compliance](https://code.claude.com/docs/en/legal-and-compliance), [Amazon Bedrock](https://code.claude.com/docs/en/amazon-bedrock)
- Claude Platform docs: [Usage & Cost API](https://platform.claude.com/docs/en/manage-claude/usage-cost-api), [Rate limits](https://platform.claude.com/docs/en/api/rate-limits), [Rate Limits API](https://platform.claude.com/docs/en/manage-claude/rate-limits-api), [Token counting](https://platform.claude.com/docs/en/build-with-claude/token-counting)
- [The Register: Anthropic clarifies ban on third-party tool access](https://www.theregister.com/2026/02/20/anthropic_clarifies_ban_third_party_claude_access/)
- OpenAI: [Codex pricing/limits](https://learn.chatgpt.com/docs/pricing), [Usage & Costs API cookbook](https://developers.openai.com/cookbook/examples/completions_usage_api), [Usage completions reference](https://developers.openai.com/api/reference/typescript/resources/admin/subresources/organization/subresources/usage/methods/completions), [Rate limits guide](https://developers.openai.com/api/docs/guides/rate-limits)
- AWS: [Bedrock runtime CloudWatch metrics](https://docs.aws.amazon.com/bedrock/latest/userguide/monitoring-runtime-metrics.html), [Token burndown](https://docs.aws.amazon.com/bedrock/latest/userguide/quotas-token-burndown.html), [bedrock-runtime quotas](https://docs.aws.amazon.com/bedrock/latest/userguide/quotas-runtime.html), [TTFT & EstimatedTPMQuotaUsage blog](https://aws.amazon.com/blogs/machine-learning/improve-operational-visibility-for-inference-workloads-on-amazon-bedrock-with-new-cloudwatch-metrics-for-ttft-and-estimated-quota-consumption), [What's new: Bedrock Service Quotas (2026-05)](https://aws.amazon.com/about-aws/whats-new/2026/5/amazon-bedrock-service-quotas/), [Cost Explorer pricing](https://aws.amazon.com/aws-cost-management/aws-cost-explorer/pricing/), [Cost Explorer overview](https://docs.aws.amazon.com/cost-management/latest/userguide/ce-what-is.html), [AWS SDK for Swift auth](https://docs.aws.amazon.com/sdk-for-swift/latest/developer-guide/authenticating.html), [aws-samples Bedrock quota dashboard](https://github.com/aws-samples/sample-quota-dashboard-for-amazon-bedrock)
- Apple: [App Sandbox Temporary Exception Entitlements](https://developer.apple.com/library/archive/documentation/Miscellaneous/Reference/EntitlementKeyReference/Chapters/AppSandboxTemporaryExceptionEntitlements.html)
- Repos: [steipete/CodexBar](https://github.com/steipete/CodexBar), [openai/codex](https://github.com/openai/codex), [ryoppippi/ccusage](https://github.com/ryoppippi/ccusage), [tddworks/ClaudeBar](https://github.com/tddworks/ClaudeBar), [hamed-elfayome/Claude-Usage-Tracker](https://github.com/hamed-elfayome/Claude-Usage-Tracker), [f-is-h/Usage4Claude](https://github.com/f-is-h/usage4claude), [steipete/VibeMeter](https://github.com/steipete/VibeMeter), [figueiredouc/claude-limits](https://github.com/figueiredouc/claude-limits), [kenn-io/vibepulse](https://github.com/kenn-io/vibepulse), [junhoyeo/tokscale](https://github.com/junhoyeo/tokscale), [ClaUse Bar (App Store)](https://apps.apple.com/app/id6759294136)
