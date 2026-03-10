# TODO - Meeting Summarizer

Based on pre-publish review and improvement discussion (March 2026).

---

## Before Publishing to GitHub

- [ ] Replace real AWS credentials in `Config.swift` with placeholder values
- [ ] Add `.gitignore` (exclude `.DS_Store`, `xcuserdata/`, `DerivedData/`, `*.xcuserstate`)

---

## Security

- [x] Add ASH pre-commit hook (`.pre-commit-config.yaml`)
- [x] Add Security section to README
- [ ] Consider migrating credentials to AWS Cognito Identity Pools or `.xcconfig`

---

## v2 Features & Improvements

### High Priority
- [ ] **Credentials management** — move away from `Config.swift` hardcoded keys
- [ ] **Better error handling** — surface meaningful errors in the UI instead of silent failures / in-app logs
- [ ] **IAM key rotation** — document or automate regular key rotation

### Medium Priority
- [ ] **Transcription polling** — replace fixed 60-attempt loop with exponential backoff + better "still working…" UI state
- [x] **Background processing** — saves job on start; resumes polling on app reopen; shows "Resuming transcription..." status
- [x] **Cancel processing** — cancel button stops upload/transcription/summarisation and releases microphone
- [ ] **Multi-language support** — add language picker (AWS Transcribe supports 30+ languages)
- [ ] **Persist chat history** — save conversation history per meeting, currently resets each session

### Nice to Have
- [ ] **iCloud sync** — access meetings and transcripts across iPhone/iPad/Mac
- [ ] **Export to PDF** — formatted export, not just plain text share
- [ ] **Speaker identification** — use AWS Transcribe diarization (who said what)
- [ ] **More audio formats** — currently M4A focused; support MP3, WAV, etc.
- [ ] **Transcript editing** — let user correct transcription errors before summarising

---

## Documentation & Publishing

- [x] Write `README.md`
- [x] Generate AWS architecture diagram (`generated-diagrams/meeting-summarizer-architecture.png`)
- [ ] Add architecture diagram to README
- [ ] Create GitHub repo and push
- [ ] Add README badge once repo is public

---
