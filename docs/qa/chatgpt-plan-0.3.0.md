# ChatGPT plan connection — 0.3.0 / build 6

## Implemented

A separate ChatGPT provider uses the official OSS/local public-client flow. Browser authorization is explicit, the callback listens only on IPv4 loopback with a three-minute timeout, and state/nonce/PKCE are per attempt. RSA-signed ID tokens must match issuer, audience, expiry, issue time and nonce. Reauthorization also matches the previously verified subject and client. Tokens are stored together in Keychain, never in library.json; a persistent opaque installation host ID is stored in preferences. Each provider entry is a separate account/workspace registration.

Refresh uses the saved client, preserves/updates granted scopes and rotates tokens together. Refresh is serialized within an actor and across local instances using an advisory file lock. Disconnect clears local tokens, attempts renewable-session revocation, and distinguishes remote failure from confirmed revocation. The registration remains for reconnection. Temporary request failures do not erase credentials.

The account catalog preserves model order and display names. Model requests use the fixed public Responses endpoint, store:false and stream:true. No answer is committed before response.completed. Function calls and opaque reasoning output survive tool continuation; execution still uses Voxstead's existing approval flow. Late failures, interrupted streams and usage limits stop the response. Automatic card scanning stops after a ChatGPT failure. No silent API fallback or change of billing source occurs.

Settings includes browser sign-in, model selection, disconnect and Manage usage. AI composers display the active ChatGPT billing source. English UI and existing API/local providers are preserved. The paid/managed build must disable VoxsteadAllowsChatGPTPlan until commercial approval and configuration are complete; the flag also blocks existing credentials from inference.

## Automated evidence

Command:

```sh
VOXSTEAD_TEST_AUDIO=/tmp/voxstead-capture-check.aiff DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test
```

PASS: 23 tests across 4 suites. Eight ChatGPT tests cover callback binding, signed identity validation and rejection, loopback rejection/cancellation, scope handling, streaming failure, Responses tool continuation and fixed destination, refresh/catalog/revocation, and refresh coordination between separate connection instances. Other suites cover transcript conversion, real local speech fixture, library compatibility, guide state, API-provider fixtures, MCP transport and tool approval.

All ChatGPT transport credentials and responses in automated tests are synthetic. Temporary test Keychain records are removed. Passing these tests does not prove account eligibility, live OAuth completion, real quotas, remote token renewal or actual subscription inference.

## Native UI evidence

The packaged build opens Settings → AI providers → Continue with ChatGPT. Inspected the native connection panel visually: sign-in, billing explanation, Manage usage and disabled Use this connection before authorization are present. The button starts the browser and displays a cancelable waiting state; the official OpenAI browser flow reached email verification. No password or verification code was entered by the agent, and no plan-use consent was accepted by the agent.

The user completed OpenAI verification and consent. PASS: verified connection saved, ChatGPT plan permission enabled, real account model catalog loaded, and GPT-6-Luna selected. After rebuilding/relaunching, the profile and model remained. One initial panel inspection showed no restored account; Keychain metadata and a redacted record check confirmed credentials were present. Reopening the panel restored the verified account and catalog. Added an explicit restoring state with sign-in disabled during the read; the transient display was not evidence of credential loss. On the final rebuild macOS SecurityAgent was active while the panel displayed Restoring saved connection. Computer-use access to SecurityAgent was blocked by the tool. The user explicitly authorized the Keychain prompt on their Mac; the final packaged app then displayed the restored account, enabled plan and model. This is a local ad hoc signing/update UX limitation; stable Developer ID signing and customer upgrade tests remain release gates.

PASS: native Test connection sent only “Reply with OK only” (plus a brief system instruction) using the user's selected plan/model and displayed “ChatGPT responded successfully: OK”. No transcript was used in this test. The test counts against the authorized ChatGPT plan.

Real sign-out/revocation, real usage-limit exhaustion, and long-term token renewal remain untested against the live account; those paths have synthetic coverage. The user's working connection was left intact.

## Business and distribution boundary

See ../product/managed-edition.md. This local ad hoc build is not a notarized customer release. No billing, checkout, entitlement, managed AI backend, or commercial OpenAI approval was created. The $15/month scenario in the product note is a hypothesis for cost testing, not a price announcement.

## Official references checked 2026-11-15

- https://developers.openai.com/siwc/token-sharing-open-source/sign-in
- https://developers.openai.com/siwc/token-sharing-open-source/profiles-and-sessions
- https://developers.openai.com/siwc/token-sharing-open-source/models-and-inference
- https://developers.openai.com/siwc/token-sharing-open-source/errors-and-recovery
- https://developers.openai.com/siwc/ui-ux-guidelines

Final checks: PASS `git diff --check`; PASS packaged 0.3.0 build 6 ad hoc signature/launch verification; PASS final native account restoration after the user handled the macOS Keychain prompt. No further authentication, purchase, billing or production mutation was performed.
