# Capture stability evidence — 0.2.3

## Symptom and environment

User reported unexpected exits near startup. Two local Voxstead reports dated 2026-11-15 (004931 and 004940) contain EXC_BREAKPOINT/SIGTRAP in RealtimeMessenger.mServiceQueue, `_dispatch_assert_queue_fail`, `_swift_task_checkIsolatedSwift`, and the microphone tap closure in SpeechCapture.start. Tested on Apple Silicon, macOS 27.2, using full Xcode; deployment target remains macOS 26.

## Competing hypotheses and observations

| Hypothesis | Prediction | Evidence / result |
| --- | --- | --- |
| Library decoding or initial UI causes launch crash | Fault before capture begins, in persistence or UI | Contradicted for these two reports: both terminate inside the audio tap. Workspace launch also succeeds. |
| Microphone callback inherits MainActor isolation | Audio thread invocation fails an executor assertion | Supported by both crash stacks and construction inside MainActor-isolated start. |
| Bad PCM fixture explains test-helper crashes | AnalyzerInput conversion crashes independently of isolation | Confirmed for an initial float32 test fixture; changed test target to valid int16. These helper reports are not Voxstead user crashes. |

## Repair

Construct the AVAudioNodeTapBlock in a nonisolated factory; keep UI/state on MainActor and existing feed conversion on the source queue. Do not disable actor checking or assume an executor.

Replace transient generic error alerts with persistent, selectable recovery banners, including Settings and Dismiss. Clear stale errors on an explicit capture retry. Close an orphaned live panel and return to the workspace when its session ends or setup has already failed.

## Regression protection

`microphoneTapRunsOffMainActor` constructs and invokes the tap from detached work, checks converted input and dropped buffers. Removing `nonisolated` produces a compile-time actor-isolation failure at detached construction (observed red); restoring it passes. This is not a reproduction of the original runtime thunk trap.

`audioFeedTranscribesARealFixture` is opt-in via VOXSTEAD_TEST_AUDIO. It passes a real PCM file through the tap, converter and SpeechAnalyzer, finalizes, and asserts recognized words. It requires installed English speech assets. Generate its synthetic fixture with:

```sh
/usr/bin/say -o /tmp/voxstead-capture-check.aiff 'This is a Voxstead recording test. We agreed to send the project draft on Tuesday. Alex will review the draft.'
VOXSTEAD_TEST_AUDIO=/tmp/voxstead-capture-check.aiff DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test
```

## Native observations after repair

- Microphone-only: start, live state, pause, resume, end passed without exit.
- Microphone plus all Mac audio: start, live transcription from both labeled sources, pause, resume, end, and saved transcript passed without exit. Existing OS permissions sufficed.
- An earlier combined-audio attempt returned an empty live panel without a visible error. This motivated the recovery changes; the next attempt succeeded, so the underlying intermittent setup failure and banner rendering on that specific failure are not reproduced/verified.
- The saved QA meeting remains in the local library. No transcript was sent to a model provider.
- No private report payload or captured transcript is included here.

## Evidence limits

Live cloud answers, debrief, coach, MCP, automatic multilingual Whisper dictation, all language combinations, and long-duration recording are not certified by this repair. There is no guarantee of zero future bugs. UI stays English. No external release or subscription service was published.

Reference: Swift SE-0423 dynamic actor isolation checks: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0423-dynamic-actor-isolation.md

## Final validation

- PASS: full Swift Testing run, 15 tests across 3 suites, including real fixture transcription, library migrations, first-use guide, provider mock round-trips and MCP fixtures. Provider mocks do not prove live service access.
- PASS: `git diff --check`.
- PASS: packaged 0.2.3 build 5, ad hoc signature verification and launch survival via `script/build_and_run.sh --verify`. This smoke check alone does not prove capture; native capture results are recorded above.
