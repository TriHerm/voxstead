# Meeting assistance — local implementation

The app interface remains English. Generated debriefs, coaching and meeting answers now use the language of the transcript, rather than the English quick-action labels. Mixed-language live replies follow the latest substantive turn; saved summaries follow the predominant language; live Catch me up follows the latest substantive turn. This is an instruction to the selected model, not a guarantee of language detection accuracy.

The live panel has three per-meeting support options:

- Conversation: suggested replies and recaps in the spoken language.
- Language support: suggested wording in the spoken language, plus a translation and explanation in the user's chosen language. “Explain the latest speech” requests a translation of the latest excerpt. Requests are on demand, not a continuous interpreter. Speech recognition still needs the correct Speech language selected when starting the meeting.
- Interview practice: answer structure and clarifying questions grounded in the user's actual experience, with no invented credentials or results.

Support preferences persist with the meeting. Earlier saved meetings remain readable without migration. Debriefs always follow the transcript language, even when language support was enabled. Existing debriefs are not automatically rewritten.

Catch me up remains in the meeting language in every support mode, including when the preferred explanation language differs. Translation is requested separately with “Explain the latest speech”.

The latest answer has visual priority. Native Liquid Glass buttons and adaptive bar materials provide restrained depth; answer text stays on a stable reading surface. Reduced-transparency settings use an opaque bar background. Live transcript and answer-length/MCP controls can be expanded. Provider disclosure, cancellation, pause/end and tool approval remain available. Automatic cards keep their existing opt-in cadence; no additional background model requests were introduced. Cards returned after support preferences change are discarded.

Validation: multilingual transport fixtures (Spanish, French and Japanese) assert the language policy sent for debriefs and all three live modes; these fixtures do not measure real-model translation accuracy. Automated library compatibility/persistence checks and existing transport, ChatGPT, MCP, debrief and audio regression tests. Actual multilingual model quality and a live bilingual/interview session still require human validation. No claim of universal language support or simultaneous interpretation.

## 0.3.1 local installation

Installed in `/Applications/Voxstead.app` and refreshed `dist/Voxstead.app`. The installed app launched and displayed the existing library. A searchable explanation-language selector replaces free-text entry, using the Foundation ISO language catalog with English and native names. This catalog is not a guarantee that every AI provider translates every language equally well; speech-recognition availability remains independent. Existing free-text preferences are preserved until a new choice is selected. All 27 automated tests passed, including native-name search and library persistence. The picker was compiled and tested at the catalog level; no new microphone recording was started for UI verification.
