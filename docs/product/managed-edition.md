# Voxstead: open source and managed service

## Product decision

Keep one application and one core experience. Dictation, local transcripts, notes, checklists, exports, and bring-your-own-provider connections remain available in the open-source edition. A future managed subscription should buy convenience: a supported build, built-in AI without API keys, clear usage information, and support. This document describes intended work, not an available service or a pricing commitment.

Do not create separate feature mazes or lock access to existing local transcripts when a subscription ends. Both editions should use the same transcript, debrief, and tool-approval flows. Keep the English interface independent of recognition and translation languages.

## Current experience

Home offers dictation and meetings first. AI configuration is optional. Settings starts with an overview of recording, the default provider, and data handling. Provider endpoints live under Advanced. MCP is under Tools. The local OSS build includes a ChatGPT plan connection through OpenAI's official sign-in flow. It is separate from a Voxstead account. No managed entitlement, checkout, or upgrade button is shipped.

The default provider persists across launches. Search combines session kind and transcript/title matching. Home shows the three latest sessions. Copy and export give transient confirmation, and removing provider credentials or tool connections requires confirmation.

## Smallest useful managed release

1. Package the multilingual recognition engine and verified model assets through a supported installer or an in-app setup flow. A paying customer's first dictation must not require a shell or compiler. Show model size, progress, cancellation, retry, and local disk requirements.
2. Sign and notarize the app, and provide a verified update path. The current ad hoc development build is not the customer distribution artifact. Rebuilding it prompted for Keychain access during QA; require stable signing and validate credential continuity across customer updates.
3. Add account sign-in and a server-owned managed provider adapter. Keep vendor secrets on the server. Reuse the model-client interface so the existing assistant workflows need no new UI.
4. Enforce subscription entitlements and usage limits on the server, including idempotent billing events. Show usage and the next reset date, and stop clearly at the allowance rather than silently charging overages. Price and allowances remain undecided until measured.
5. Add hosted checkout and billing management only once billing, cancellation, expiry, retry, and entitlement reconciliation are exercised end to end. Cancellation leaves local transcripts and exports accessible; users can switch to their own provider.
6. State exactly which text reaches the managed service and its upstream providers. Define and implement retention and deletion before making privacy promises. Do not silently upload the local library or enable automatic analysis.

Keep MCP optional and retain per-call approval in both editions. No cloud library sync, team administration, marketplace, CRM, or multi-tier feature matrix is necessary for the first managed release.

## Release evidence still needed

- First-run dictation without developer tools on a clean Mac.
- Real meeting audio from a browser and a native calling app, including pause/resume, permission denial, and interruption recovery.
- Cursor insertion and clipboard fallback in commonly used apps.
- VoiceOver and keyboard-only review, plus light and dark appearance.
- Managed authentication, billing, entitlement, limits, and cancellation integration tests against the actual service.
- Measured cost and latency per real workload before setting a subscription price.

Local tests and synthetic fixtures are engineering checks, not customer or revenue validation.


## Subscription model with ChatGPT connections

### Recommended initial offer

Keep two clear choices, with one paid tier rather than a matrix:

| Offer | Customer gets | AI billing | Status |
| --- | --- | --- | --- |
| Voxstead Open Source | Local recording, transcripts, exports, existing assistant features, optional MCP; user manages installation and AI connection | Their eligible ChatGPT plan, their API provider, or their local model | Local developer build; ChatGPT sign-in and one response verified on one account |
| Voxstead Managed | Supported installation, packaged speech setup, signed updates, built-in AI with a defined allowance, and support | TriHerm supplies API usage under its commercial provider account and meters the managed allowance | Proposed; no checkout, backend, entitlement or paid service exists |

The paid offer should sell dependable setup and operation. Do not require payment to access a user's existing recordings, exports, or OSS capabilities. ChatGPT sign-in alone is not an entitlement to Voxstead Managed. Conversely, paying TriHerm does not create or upgrade a ChatGPT subscription.

Start with one monthly managed plan. Before publishing a price, measure variable AI cost per active user and per meeting under real workload samples. A **$15/month test price is a hypothesis**, not an announced offer or validated willingness to pay. At a hypothetical 70% gross-margin target, the total variable budget is $4.50 per subscriber per month (provider usage + payment fees + variable hosting/support). If measured costs exceed that budget, lower included usage, change the price, or improve efficiency before launch. Use measured p50/p90/p99 workloads; do not base an allowance only on the average. Local speech recognition does not consume paid inference, but summaries, follow-up questions, coaching, and automatic cards do.

Do not advertise unlimited AI. Define a visible monthly allowance and reset time; stop at the limit. Additional credits or annual billing can wait until metering, cancellations and margins are proven. No automatic overages and no automatic fallback from ChatGPT to paid APIs.

### ChatGPT in a paid product

The official OSS/local integration documentation directs paid or remotely hosted apps to OpenAI's interest process. Keep the paid-build flag `VoxsteadAllowsChatGPTPlan` **false until the commercial integration is confirmed**. The flag controls new sign-in and use of existing plan credentials. A future approval must also define identity/client configuration for the paid product; enabling a Boolean alone is not a commercial integration.

After approval, a managed subscriber may optionally select **Use your ChatGPT plan** as their AI source. Show that option separately from **Included Voxstead AI**, with the active source next to the composer and a link to its usage page. ChatGPT limits and applicable credits stay with OpenAI. Keep the same OSS route available independently; there is no reason to force a support subscription just to connect an existing plan.

### Minimal customer journey

1. First use: dictate locally, without creating an account.
2. When the customer wants AI: choose their existing ChatGPT connection, an API/local provider, or the managed service once available.
3. Managed onboarding: explain the allowance, price, renewal and cancellation, then use hosted checkout. Grant service only after verified server-side entitlement.
4. In the workspace: show the selected AI source and its usage controls. Each request has exactly one billing owner.
5. On expiry/cancellation: keep local data and exports working. Stop new managed requests at entitlement expiry; let the user choose another connection explicitly.

### Implementation sequence and launch gates

- Sign-in, scopes, model catalog, a short answer, and restoration after relaunch have been verified with one consenting account. Complete real token-renewal, revoke/reconnect, usage-limit, and broader account eligibility tests.
- Validate local installers, signed/notarized update delivery and multilingual recognition on a clean Mac.
- Build a first-party managed account, server-side provider gateway, request idempotency, entitlement verification and usage ledger. Never upload ChatGPT OAuth tokens to TriHerm's service or use subscriber tokens to serve other customers.
- Exercise checkout, webhook replay/out-of-order events, cancellations, refunds and reconciliation in test mode; publish no prices or promises before this works.
- Run a small opt-in pilot and measure actual value, support burden, latency and cost before public pricing. Customer/revenue results remain unverified.

Sources checked 2026-11-15:
- [OpenAI OSS/local plan usage and paid-app interest process](https://developers.openai.com/siwc/token-sharing-open-source)
- [Sign-in and plan-usage UI requirements](https://developers.openai.com/siwc/ui-ux-guidelines)
- [ChatGPT account, session and revocation behavior](https://developers.openai.com/siwc/token-sharing-open-source/profiles-and-sessions)
