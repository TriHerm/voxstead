# Voxstead

An open-source macOS workspace for dictation, live meetings, and follow-up, from **TriHerm Labs**. The interface is in English. Speech recognition and translation have independent language settings.

## Download

Download the Apple Silicon disk image from [GitHub Releases](https://github.com/TriHerm/voxstead/releases/latest). Open the disk image and drag Voxstead to Applications. This build requires macOS 26 or later and uses an ad hoc signature. Apple notarization is pending. The release includes a SHA-256 checksum.

## First use

On a fresh workspace, the guide offers meeting setup, a bilingual example, and dictation setup. The example runs on-device with built-in responses for Explain, Catch me up, What should I say?, and Debrief. Dictation setup covers recognition language and clipboard behavior. Voxstead requests microphone access when you start an audio check or recording.

Use **Getting started** in the sidebar or **Help → Voxstead getting started** to replay the guide. You can go back or skip; unfinished progress resumes after relaunch, while skipped guides stay dismissed. Existing libraries are not interrupted by an automatic tour. The first dictation launched from the guide includes contextual Stop/copy/paste instructions.

## A simpler workspace

**Home** offers phone calls, meetings, practice, dictation, and recent sessions. Choose **Phone call** for one-on-one captions and brief replies, or **Start a meeting** to track decisions and tasks. Both support a microphone and optional Mac audio. The sidebar keeps those tools, **Ask your meetings**, **Action items**, and **Coach** in the workspace window. Use **⌘1** to return to Home, or **⌘[** and **⌘]** to move through your navigation history. Returning to a session restores its last open tab for the current launch. Filter the library by folder or session type, or search titles and transcripts. Use the folder menu to create a folder, then move a session from its context menu. **Settings → General** explains local recording and optional AI. Select a default provider there to keep it across launches.

This build is the open-source, bring-your-own-AI edition. A managed subscription for simpler setup and built-in AI is planned, but there is no billing or hosted AI service in this build. See the [managed edition plan](docs/product/managed-edition.md).

## Run locally

Voxstead requires macOS 26 or later, a Mac that supports Apple SpeechTranscriber for live transcription, and Xcode with Swift 6.2 or later.

```bash
./script/build_and_run.sh
```

The script builds and opens `dist/Voxstead.app` with a local ad hoc signature. Use `--build-only` to package the bundle without opening it. Quit a running workspace copy before rebuilding so it can finish the capture and save. From Codex, use **Run**. If upgrading from the Cluinn OSS preview, Voxstead copies the old library once and continues to use the existing Keychain entries.

## Dictation

- Hold **Control–Option–D** while speaking, then release. Voxstead saves the result and copies it to the clipboard by default. To write into the original field, enable **Insert dictated text at the cursor** under **Settings → Recording** and grant Accessibility access. If the field changed or doesn't support insertion, the text goes to the clipboard.
- Under **Settings → Recording → Microphone**, choose **System default** or an available input. Voxstead remembers the choice for dictation and meetings without changing the macOS input. You can also choose the input in **Start meeting** or while the meeting is paused.
- For **Automatic (Whisper)**, run `./script/setup_dictation.sh` once. CMake is required. Setup compiles the pinned [whisper.cpp release](https://github.com/ggml-org/whisper.cpp/releases/tag/v1.9.5) and downloads and verifies a multilingual model of about 148 MB. Whisper detects the dominant spoken language per dictation or imported audio file. Under **Settings → Recording**, you can also select an explicit language from those available to Apple's on-device recognizer. Live meetings use the separately selected language.
- Under **Settings → Personalize**, set an optional output language or add writing instructions for individual apps. Those options send dictated text to the selected provider. Voxstead preserves the original transcript alongside the processed output. Add names and technical terms to **Speech dictionary** to help Apple’s on-device recognizer.
- Use **⌘⇧I** to transcribe an audio file. In the **New session** menu, **Add transcript** can also bring existing text into a dictation or meeting.

## Phone calls on speaker

1. Choose **Home → Phone call** and select the spoken language. Under **Call audio**, choose **Microphone only** for a phone on speaker near your Mac. For a call on the Mac, select the app playing the call or **Microphone + all Mac audio**. **Check audio** previews the selected inputs.
2. Under **Before the call**, optionally add the caller’s name and notes such as goals, dates, codes, and limits. These notes are pinned above the live captions. Replies default to English with an optional meaning in Spanish.
3. Choose **Start listening**. With Mac audio, the microphone is labeled **You** and the app audio is labeled **Caller**. With microphone-only audio, say a few words and choose **That’s me** beside your line. That mode uses a local model that downloads the first time. After a pause, mark your voice again in microphone-only mode.
4. Use **What should I say?** or **⌘⌥3** for up to two short sentences. **Clarify** gives you a question to ask aloud and **Simpler** rephrases a suggested answer. The reply menu offers optional suggestions on detected questions and a phrase to ask for a moment.
5. **End & recap** finishes the transcript and opens a recap with agreements, dates, open requirements, and next steps. Choose **End without recap** from the arrow to save the call for later.

The Mac transcribes audio and estimates who spoke from the selected microphone. Similar or overlapping voices can be ambiguous. To correct a label, right-click the line where you spoke and choose **Mark this voice as mine**. The transcript is saved in your library. Suggestions send recent text and your preparation notes to your selected AI provider. Generating a recap sends the finished transcript.

## Live meetings

1. Choose **Start a meeting** and select the microphone, all Mac audio, or a running app alongside the microphone. For a browser call, choose the browser playing it. Voxstead captures the selected audio locally and does not send a bot to the call. macOS can request microphone and Screen & System Audio Recording access. Use **Check audio** for a temporary preview of what Voxstead hears. Under **Language**, choose the language people will speak and add any specific names or terms. Turn on **Translate live captions** to choose the output language. Prepare the Apple language assets there when prompted.
2. **Preparation notes** lets you write goals and ask for an opening line, a question, and a next step before recording. In the live panel, **Explain** uses your preferred language, **Catch me up** starts with the finalized transcript and remembers its place for later recaps in the meeting language. **Recap from start** revisits the whole transcript. **What should I say?** uses recent speech, relevant earlier excerpts and the latest recap when available to suggest one short phrase in the language of the conversation. **Language support** can show its meaning below, and **Copy phrase** copies the phrase on its own. The live caption switch translates supported speech on-device from the recognized text, including previews of speech that is still in progress. You can change the caption language in the transcript header. Use **⌘⇧L** in Voxstead to reopen the live panel.

   Click the timestamp under the quick actions to open the latest part of the transcript covered by the saved recap.

   If the conversation changes language, pause the meeting, pick the new **Spoken language**, and resume. The new setting applies to the rest of the recording.
3. **Scan now** checks the recent transcript for useful follow-up cards, such as unresolved questions. Optional automatic scans check new transcript text about every 45 seconds while the meeting is recording. Mark a card resolved or dismiss it from its menu. Under Debrief, the card history links to the supporting transcript. Asking and scanning send excerpts to the selected provider.
4. After ending, open **Debrief** for a summary, decisions, notes, and an editable action-item checklist. Choose a General, Follow-up or Interview template. Regenerating refreshes pending AI suggestions and keeps tasks you edited or completed. **Prepare follow-up** brings the decisions and open actions you choose into editable preparation notes for another meeting. **Action items** shows pending tasks across meetings. **Coach** reviews the communication habit you set and offers language to try when it can ground the suggestion in a microphone transcript passage. Automatic post-meeting debriefs and coaching are opt-in.
5. **Ask your meetings** searches saved transcripts and notes and sends excerpts from up to eight relevant meetings to the selected provider. Scope a question to a folder or jump to an excerpt from the sources below an answer.

The transcript identifies microphone and Mac audio separately. Remote participants share the Mac audio channel. Use a transcript row’s context menu to label its speaker manually. Audio is processed on the device and is not retained in the library. Automatic dictation uses temporary recordings that are deleted after processing. The library lives at `~/Library/Application Support/Voxstead/library.json`. **File → Back Up Library…** exports a JSON snapshot. **Restore Library Backup…** reviews and replaces the workspace from a snapshot, and keeps the previous file in **Library Recovery**. Deleting a meeting also deletes saved cross-meeting answers that used it. Quit waits for active capture to finish and for pending changes to save.

## Providers and MCP

Add profiles in **Settings → AI providers**. Enter your API key when required, then use **Browse available models** to search the provider’s catalog. You can also enter a model ID manually; base URLs are under **Advanced**. Catalog availability does not guarantee chat/tool compatibility, so **Test connection** sends a short test prompt. Supported profiles include OpenAI, Anthropic, Google Gemini, OpenRouter, Ollama, and other Chat Completions-compatible endpoints.

Under **Settings → Tools**, add a **Local process (stdio)** using an absolute executable path and one argument per line, or **Streamable HTTP** using a full server URL and an optional bearer token. Local processes run with your permissions. **Test connection** shows the advertised tools.

Enable the server and select **Use MCP** in a session or the live panel. When the model requests a tool, Voxstead shows the server, tool, and arguments and asks for approval. The selected model receives the textual or structured result. Keys and credentials are stored in Keychain. HTTPS is used for remote endpoints and HTTP is allowed for localhost. MCP supports tool calls over POST and bearer authentication. Interactive OAuth is outside this version.

## Development

```bash
xcrun swift test
```

Use full Xcode with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` if the standalone Command Line Tools SDK lacks SwiftUI macros. The tests use Python 3 for local test servers.

[Product research notes](docs/analysis-cluinn.md) · [MIT license](LICENSE)


### Use your ChatGPT plan (local OSS preview)

Open **Settings → AI providers → Continue with ChatGPT**. Sign in in your browser, review OpenAI's plan-usage permission, choose an available model, and select **Use this connection**. Your credentials stay in macOS Keychain. No API key is required for this connection. You can add another account/workspace as a separate connection.

AI calls use the selected account's allowance or applicable credits; **Manage usage** opens ChatGPT's controls. Voxstead does not automatically switch to API billing when a limit is reached. This does not import ChatGPT conversations or purchase a Voxstead subscription. Disconnect from the connection's settings; if remote revocation cannot be confirmed, also disconnect in ChatGPT settings.

This integration is for the local OSS edition. Sign-in, model discovery, persistence and a short response were verified with one eligible account. Other account types, live revocation and quota exhaustion still require acceptance testing. Paid/hosted distribution requires a separate commercial integration process; see [the business model](docs/product/managed-edition.md). Managed builds must disable `VoxsteadAllowsChatGPTPlan` until that integration is approved and configured.
