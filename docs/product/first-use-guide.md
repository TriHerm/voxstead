# First-use guide — 0.2.2

A three-step English guide introduces local dictation, speech-language and clipboard preferences, then a first recording. It offers Back, Skip for now, an alternative meeting setup, and a return to the workspace. Getting started in the sidebar and the Help menu reopen it from step one.

Fresh workspaces open the guide automatically. Existing library files do not receive an unexpected tour. Optional settings fields preserve compatibility with older files. Progress is saved on navigation, unfinished guides resume, and skipping/finishing persists dismissal. Choosing a next task queues it until the sheet has dismissed, avoiding overlapping setup panels. The guide does not record or call a model on opening. The global dictation shortcut is ignored while the guide is visible.

Starting dictation from the last step enters the existing capture flow and adds contextual instructions to that session: speak, stop, copy, and paste. This session marker is temporary and does not change the transcript format. Speech permissions are requested by the existing recording flow, not preemptively by the guide. The UI language remains independent of the selected recognition language.

## Validation

- 13 Swift tests passed, including new first-launch, resume (including step zero), skip persistence, replay, upgrade behavior, and deferred one-time handoff tests. Temporary test libraries were used; no microphone was started by the tests.
- Native UI: inspected all three steps, used Enter to advance, handed off to meeting setup, canceled without recording, reopened the guide, and used Escape to skip. Text and controls were visible in the inspected dark appearance.
- Build-and-run verification and ad hoc signing passed.
- Actual first-use microphone permission/denial, recording and contextual result banner, VoiceOver, and light appearance were not exercised in this iteration. Existing transcription tests do not substitute for those runtime checks.

## 0.3.9 meeting-first entry

The welcome screen offers meeting setup, a bilingual practice meeting, and the existing dictation setup. The practice example uses built-in transcript turns and responses, runs on this Mac, and keeps its progress in the practice view. Use Catch me up, continue the example, and use the recap again to see only the changes since its previous result.

Home and the sidebar both open practice. Home also opens meeting setup directly. Meeting setup separates transcription language from the optional explanation language and lets the user check the microphone and remote audio before recording.
