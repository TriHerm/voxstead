# Reference research — Cluinn 1.7.43

The installed arm64 bundle at `/Applications/Cluinn.app` declares push-to-talk dictation and live call transcription. It combines Electron with native helpers. The following observations are from static artifacts.

| Observation | Evidence |
| --- | --- |
| The app manifest describes dictation and call transcription routed through a service. The ASAR also contains local Whisper modules and provider clients. Effective routing depends on configuration and runtime behavior. | ASAR manifest and the modules `src/main/index.js`, `src/main/meeting-capture.js`, and `src/main/ipc.js`. ASAR SHA-256 `e6147df46b690da1e18590e9f62b64d2c730217232c0a4c0d2d17e3ec2763d9b`. |
| REA reported five Electron windows and 373 literal IPC channels. Literal registrations cover dictation, capture, call search, queries, export, and account management. | REA view `ev_8cf3dc480c9393568ffb897d4810dc260a9015739489e853829552a4e3180fe5` and literal registrations in `src/main/ipc.js`. |
| Hopper analyzed 866 procedures and 229 string objects in the Mach-O `cluinn-observer` helper. A bounded accessibility-symbol search returned zero matches. The Mach-O loads ScreenCaptureKit and Vision. | Hopper/REA summary `ev_d29749fed7f43e699941cb66798c9d4f530469cfcfe5741287f76f102bb12614`, Hopper search `ev_a3c94307aceb1af85e26cfbee3082555c7de010de794539fa0812638502262b1`, and Mach-O inspection `ev_98409b0e15ecd6a61682e1a8c2e2c2726de55c89b18b2f574b4504b35b722003`. |

Static coverage was partial. REA found four hash mismatches in unpacked mouse and ONNX components and treated those bytes as untrusted. Active code paths, defaults, and the original app's performance remain unverified.

## Voxstead implementation

- The initial preview implemented global dictation, local notes and search, meeting capture, and export using new Swift code. Independent model profiles and confirmed MCP calls use public APIs.
- User-supplied screenshots informed the floating live meeting panel, proactive cards, debrief, coach, and personalization.
- Voxstead 0.2 has its own name, icon, bundle identifier, and English interface. ScreenCaptureKit captures the chosen audio source, Whisper supplies automatic dictation language detection, and Apple SpeechAnalyzer supplies live transcription in a selected language.

Public interfaces include [SpeechAnalyzer](https://developer.apple.com/documentation/speech/speechanalyzer), [ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit), [whisper.cpp](https://github.com/ggml-org/whisper.cpp), the [MCP Swift SDK](https://github.com/modelcontextprotocol/swift-sdk), and the [MCP transports specification](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports).
