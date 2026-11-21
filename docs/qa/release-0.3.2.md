# Voxstead 0.3.2 release preparation

| Area | Acceptance check | Evidence |
| --- | --- | --- |
| Library | A corrupt original remains untouched. Starting a capture or importing while it cannot be opened fails. | Automated corrupt-library regression. |
| Long debrief | Decisions from the beginning, middle and end reach the consolidated result. | Local fixture over 64,000 characters. The fixture tests coverage and orchestration. Real provider quality remains unmeasured. |
| Actions | Regenerating replaces pending AI suggestions and preserves edited, completed and legacy tasks. | Automated persistence and reconciliation tests. Older tasks without provenance are retained. |
| Deletion | Cross-meeting answers that used a deleted meeting disappear. Unrelated answers remain. | Automated saved-library regression. Previous exports and backups remain separate files. |
| Shutdown | Quit waits for audio finalization and save. A failed write keeps the window open and offers retry and backup. | Automated save failure and retry regression. Verify quit during microphone capture, during pause and during Whisper processing on a test Mac. |
| Audio | Off-main-actor microphone callback and on-device speech from an audio file. | Automated suite with `VOXSTEAD_TEST_AUDIO`. Verify long calls, Bluetooth, sleep and device changes separately. |
| AI | Provider transports, ChatGPT stream parsing, language instructions and MCP approval. | Local fixtures. Measure live latency, translation and recovery with real providers using test transcripts before distribution. |
| App compatibility | Start, pause, resume and finalize with Zoom, Meet, Teams, Webex, Slack and Discord. | Pending platform-by-platform testing on a clean Mac. |
| Distribution | Signed and notarized installer, updates, and credential continuity on a clean Mac. | Pending Developer ID and notarization. The local bundle uses an ad hoc signature. |

The release configuration built successfully and 32 tests passed with the audio fixture enabled. The installed 0.3.2 binary matches the packaged binary. The workspace opened with the existing library and exposed the folder filter, action-items entry point and three debrief templates.

The app on Apple Silicon requires macOS 26 or later. GitHub Actions has a macOS build and test workflow. It needs a repository run to verify the hosted environment.

To prepare a signed app once the Developer ID Application identity is available, package with `VOXSTEAD_BUILD_CONFIGURATION=release` and `VOXSTEAD_SIGN_IDENTITY` set to the signing identity. Submit the distribution archive to Apple’s notary service, staple the accepted ticket and validate a downloaded copy on another Mac.

The managed subscription still needs its provider gateway, usage meter, checkout, entitlements and cancellation. These are tracked in [the managed edition plan](../product/managed-edition.md).

## 0.3.3 audio preflight

- The optimized 0.3.3 build launched from `/Applications/Voxstead.app`. The installed executable matched the packaged executable.
- All 33 tests passed with the audio fixture enabled. Signal detection covers silence, stale packets, and sound in an interleaved buffer's second channel. The on-device speech test also observed signal in the same converted audio fed into recognition.
- The installed app's microphone-only check detected signal and completed on its own. The workspace library file had the same checksum before and after the checks.
- The all-Mac-audio check returned a macOS Screen & System Audio Recording permissions message on this build. Device-change recovery and continuing a real meeting with the microphone only still need acceptance testing with an authorized audio source.

## 0.3.4 library recovery and task reconciliation

- Restore validates the snapshot and reviews the number of sessions before replacing the workspace. It archives the original file in `Library Recovery` and is unavailable during capture, import, model work, or pending writes.
- Debrief sends existing task titles to the configured provider for matching. Valid references preserve completed or edited items when an action is reworded, keep the ID of refreshed suggestions, and skip tasks removed while generation was in flight. Matches are model-assisted, with normalized title matching as a fallback.
- Live Card history can open the original transcript segment. The link uses the persisted source identifier and works with existing cards created by 0.3.2 and 0.3.3.
- All 36 tests passed with the audio fixture enabled. Tests exercised a full restore using an isolated damaged library, refusal of a duplicate-session backup, preservation of the original, and matching a reworded completed task through the local provider fixture.
- The optimized 0.3.4 app launched from `/Applications/Voxstead.app`. The File menu exposed Restore Library Backup and its file chooser. The live library checksum stayed the same. Successful restoration was exercised with an isolated library in tests.

## 0.3.5 live assistance

- The live panel provides Explain, Catch me up and What should I say? in both panel sizes. Explain uses the preferred language and can target an exact timestamped passage. Recaps retain the language of the conversation and disclose when only a recent excerpt is available. Suggested replies can include their meaning in a second language.
- Preparation can run before capture using only user-entered notes. Notes are stored with the meeting when recording starts. The built-in actions do not invoke MCP. Typed questions and custom prompts retain the existing MCP controls.
- Optional on-device captions translate finalized segments in small batches. They use the selected speech language and preferred explanation language. Existing and incoming text can be translated while the live panel remains open. Original text remains visible and saved independently. Captions require a supported language pair and may need a language download.
- All 39 tests passed with the audio fixture enabled. Tests cover selected passage preservation, language instructions, isolation of preparation notes from explanation and recap prompts, and a request sent to a local provider fixture before capture.
- Apple Translation successfully translated two synthetic English sentences into Spanish on this Mac, preserving their request identifiers. This checks the native translation service using an installed pair. An end-to-end call with code-switching and unsupported or missing language assets still needs acceptance testing.
- The installed 0.3.5 app opened with the existing library. In the meeting setup, entering synthetic preparation notes enabled Help me prepare. The sheet was closed before recording or sending notes. The library checksum was unchanged.

## 0.3.6 Catch me up progress

- The first recap covers all finalized speech from the beginning. Later recaps take only newly finalized speech, including segments that arrive late from a separate audio source. The live panel shows the last covered timestamp and offers Recap from start.
- The checkpoint and answer are saved together. Failed or canceled requests leave the checkpoint intact. Speech that finalizes during a request remains available for the next recap. The marker belongs to the meeting and persists in the local library.
- A long recap processes its complete scope in bounded requests before writing the final answer. The local fixture verified that the beginning, middle and end reached the final recap. Real-provider latency and the quality of live recaps still need a call test.
- All 41 tests passed with the audio fixture enabled. The recap test verified the first request, late-arriving speech, no request when caught up, recap from start, and a simulated provider failure.
- The optimized 0.3.6 build launched from `/Applications/Voxstead.app` with the existing library. The library checksum was unchanged at launch.

## 0.3.7 Microphone selection

- Settings and meeting setup offer the system default or a connected input. A paused meeting can switch to a different microphone before resuming. A missing selection shows an error with options to reconnect or switch.
- The initial hardware check showed that the audio engine reverted an explicit input to the default during setup. The final build binds a dedicated capture session to the chosen device. The original system-default capture path remains available.
- All 44 tests passed with the audio fixture and the non-default MacBook Pro microphone enabled. The hardware test captured buffers through the meeting audio service and wrote readable audio for Whisper while the Bose headset remained the system input.

## 0.3.8 Suggested replies

- What should I say? requests one short line. The request includes recent speech, up to three relevant earlier passages and the most recent saved Catch me up recap when available. Older recaps may cover only part of the meeting.
- With reply meaning enabled, the suggested phrase and its meaning appear separately in the live panel and saved assistant history. Copy phrase copies only what the user can say.
- 45 tests passed with the speech fixture enabled. The optional hardware microphone test was skipped in this run. A local provider fixture checked the Spanish question, an older agreement, recap selection, and meaning on or off. Live provider latency and translation quality still need a bilingual call test.

## 0.3.9 first meeting and navigation

- Home and first use lead with meeting setup and a bilingual practice example. The guide defers navigation until the sheet closes. Ask your meetings, Action items, and Coach are sidebar destinations in the workspace window.
- Meeting setup separates recognition and explanation languages. Prepare follow-up carries only the decisions and open actions selected in Debrief into editable notes for a new meeting.
- 47 tests passed with the speech fixture enabled and one hardware test was skipped. New tests checked practice navigation without capture or provider activity and follow-up selection without modifying the source meeting. Home and practice were inspected using offscreen SwiftUI renders. Interactive assistive-technology and real-call checks are pending.

## 0.3.10 navigation and live recap polish

- Back and forward preserve the last tab in each open session and skip sessions removed from the library. The practice state, cross-meeting question draft and folder, and completed-task filter survive navigation during the current launch.
- The live panel brings new answers into view and wraps quick actions when space is limited. The latest recap timestamp opens the transcript at its latest covered segment, including when recognition finalizes an older turn late.
- Default meeting setup no longer preserves an empty session. 48 tests passed with the audio fixture enabled, and the optional hardware test was skipped. The navigation regression verifies deletion, tab retention, and opening a specific transcript excerpt. Interactive live-panel verification remains pending.

## 0.3.11 meeting setup and live captions

- Meeting setup puts audio and language controls in separate sections. The live panel gives the transcript and its caption controls more space, with secondary controls in their own disclosures or the options popover.
- Captions use the detected language of recognized text, with recognition settings as a fallback. Recent partial speech can be translated and revised before finalization. Supported installed pairs translate on-device, and missing language assets can be prepared from setup or the live transcript.
- 52 tests passed with the speech fixture and Apple translation assets enabled. One optional hardware microphone test was skipped. An installed English–Spanish pair translated an English fragment with a Spanish recognition preference, and a streamed audio fixture produced Spanish from a non-final result. Offscreen render checks used an isolated meeting fixture. Interactive use and latency during a real call remain to be checked.

## 0.3.12 speech recognition and live options

- Meeting recognition uses Apple's regular accuracy setting with provisional captions. Stereo input is downmixed before recognition. A finalized phrase clears only the provisional text it covers.
- Check audio previews recognized speech locally. Setup accepts names and terms for the meeting, and the paused live panel lets the user correct the spoken language before resuming. Meeting help keeps the language and reply style visible, with extra settings in two disclosures.
- 55 tests passed with the speech fixture and Apple translation assets enabled. The optional hardware microphone test was skipped. Streamed English audio yielded Spanish captions before finalization, and a synthetic Spanish clip preserved all three reference terms and returned provisional updates. Recognition accuracy and subtitle latency in real calls remain unmeasured.
