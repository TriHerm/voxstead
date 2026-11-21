# UI polish review — 0.2.1

Scope: home, Settings overview, provider setup, and meeting setup, implemented in native SwiftUI. This is a scoped implementation review using the better-ui skill, not an accessibility or whole-app certification. No separate design-system specification was present.

| Severity | Location | Before | After | Why |
| --- | --- | --- | --- | --- |
| Medium, fixed | Sources/Voxstead/Views/WorkspaceView.swift:131 | Two plain start cards without setup guidance | Consistent icon tiles, clear primary dictation action, optional AI explanation, adaptive card grid | Shared surface and icon treatment makes the first task clearer |
| Medium, fixed | Sources/Voxstead/Views/ConnectionsView.swift:55 | Settings opened directly on provider configuration | General overview with direct routes to recording and AI settings | Progressive disclosure keeps implementation details out of the first task |
| Medium, fixed | Sources/Voxstead/Views/ConnectionsView.swift:261 | Name and endpoint always competed with key/model fields | Advanced disclosure; blank required inputs disable save/test | Keeps routine setup focused and uses platform controls |
| Medium, fixed | Sources/Voxstead/Views/ConnectionsView.swift:289, :402 | Provider/server removal acted immediately | Native removal confirmation | Explicit recovery opportunity before credential deletion |

## Verification

- Inspected native rendered home in dark appearance, including empty-library and missing-provider states.
- Corrected a first rendering that unnecessarily stacked the home cards at normal window width; verified the adaptive grid shows both primary actions side by side.
- Navigated Settings → General → Manage AI providers → Add provider; verified English copy, visible focus treatment, disabled Test/Save for blank inputs, and return via Escape.
- Inspected meeting setup: audio source, editable speech language, explanatory copy, and Cancel. Did not start a recording.
- Eleven Swift tests passed, including persistence of the selected provider, stale-provider fallback, combined search/type filters, and old-library decoding. Transport and model integration tests use local fixtures.
- Build-and-run verification and ad hoc signature validation passed.
- No new motion added. Existing native controls and system semantic colors retained.

Not verified: light appearance, VoiceOver, a complete keyboard-only traversal, minimum window size, runtime credential deletion, copy/export feedback, recent-session population, and real call/cursor insertion flows. Those are not claimed as validated by the visual review. No cloud provider or subscription service was tested. A real local Ollama model was tested as described below.

Approve for the inspected UI-polish scope. Broader customer-release validation remains in managed-edition.md.

## Model setup follow-through

Added a searchable provider catalog with manual model-ID fallback. The catalog fetch sends credentials only to the configured endpoint, blocks redirects through the existing transport, supports Anthropic pagination, and does not include transcript text. Catalog listing does not certify chat or tool compatibility. Native Test connection performs a separate short query.

Observed in the app: unavailable Ollama → error/retry, launched installed Ollama → retry returned five model IDs, searched `qwen`, selected `qwen3.5:4b`, expanded Advanced via its disclosure arrow, and Test connection reported a successful real local model response. Canceled the provider draft afterward; no profile or key was persisted by this UI test. The recovery message now explicitly says to start Ollama for connection-refused failures.

The added HTTP fixture test covers authorization conventions across all six profile kinds, deduplication/sorting, Anthropic pagination, and an unauthorized response without echoing the key. These fixture checks are not live cloud-provider validation. Attempts to resize the window through the available UI automation did not change its dimensions, so minimum-window coverage remains unverified.

Protocol references consulted:
- [OpenAI model listing](https://developers.openai.com/api/reference/resources/models/methods/list)
- [Anthropic model listing and pagination](https://platform.claude.com/docs/en/api/models/list)
- [Gemini OpenAI compatibility, including model listing](https://ai.google.dev/gemini-api/docs/openai)
- [Ollama OpenAI compatibility](https://github.com/ollama/ollama/blob/main/docs/api/openai-compatibility.mdx)
- [OpenRouter model catalog](https://openrouter.ai/docs/api/api-reference/models/get-models)

The Anthropic adapter retains the existing pinned `2023-06-01` version; this change does not migrate the message API to newer version semantics.
