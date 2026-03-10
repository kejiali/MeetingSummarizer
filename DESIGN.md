# Design Document — Meeting Summarizer

## Overview

Meeting Summarizer is an iOS app that records or imports audio, transcribes it using AWS Transcribe, and generates AI-powered summaries and interactive Q&A via AWS Bedrock (Claude). It is built entirely with native Swift/SwiftUI and integrates with AWS services directly — no third-party SDKs.

---

## Architecture Overview

```
┌─────────────────────────────────────────────┐
│                  iOS App                    │
│                                             │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  │
│  │ContentView│  │ChatView  │  │History   │  │
│  │(main UI) │  │(Q&A)     │  │View      │  │
│  └────┬─────┘  └────┬─────┘  └────┬─────┘  │
│       │              │              │        │
│  ┌────▼──────────────▼──────────────▼─────┐ │
│  │           AWSService                   │ │
│  │  (S3 upload, Transcribe, job polling)  │ │
│  └────────────────┬───────────────────────┘ │
│                   │                         │
│  ┌────────────────▼───────────────────────┐ │
│  │           BedrockService               │ │
│  │     (summarize, chat via Claude)       │ │
│  └────────────────┬───────────────────────┘ │
│                   │                         │
│  ┌────────────────▼───────────────────────┐ │
│  │           AWSSigV4                     │ │
│  │   (hand-rolled request signing)        │ │
│  └────────────────────────────────────────┘ │
│                                             │
│  ┌──────────────┐  ┌───────────────────┐    │
│  │TranscriptCache│  │Core Data          │    │
│  │(local .txt)  │  │(meeting history)  │    │
│  └──────────────┘  └───────────────────┘    │
└─────────────────────────────────────────────┘
             │
             ▼ HTTPS + AWS SigV4
┌─────────────────────────────────────────────┐
│              AWS (eu-west-1)                │
│                                             │
│   S3 ──► AWS Transcribe ──► AWS Bedrock     │
│  (audio)   (speech-to-text)  (Claude Haiku 4.5) │
└─────────────────────────────────────────────┘
```

---

## Key Components

### 1. `Config.swift` — Configuration

Holds all AWS configuration constants. This file is excluded from git via `.gitignore` and must be populated locally by each developer.

```swift
enum Config {
    static let awsAccessKey = "YOUR_AWS_ACCESS_KEY"  # pragma: allowlist secret
    static let awsSecretKey = "YOUR_AWS_SECRET_KEY"  # pragma: allowlist secret
    static let awsRegion    = "eu-west-1"
    static let s3Bucket     = "your-s3-bucket-name"
    static let bedrockModel = "eu.anthropic.claude-haiku-4-5-20251001-v1:0"
}
```

---

### 2. `AWSSigV4.swift` — Request Signing

All AWS API calls must be signed using the AWS Signature Version 4 (SigV4) protocol. This app implements SigV4 from scratch using Apple's `CryptoKit` framework — no AWS SDK required.

**Signing flow:**
```
1. Build canonical request:
   METHOD + canonical_URI + canonical_query + canonical_headers + signed_headers + body_hash

2. Build string to sign:
   "AWS4-HMAC-SHA256" + datetime + credential_scope + hash(canonical_request)

3. Derive signing key:
   HMAC(HMAC(HMAC(HMAC("AWS4" + secretKey, date), region), service), "aws4_request")

4. Sign:
   HMAC(signing_key, string_to_sign) → signature

5. Build Authorization header:
   AWS4-HMAC-SHA256 Credential=.../aws4_request, SignedHeaders=..., Signature=...
```

**Service-specific quirks handled:**
| Service | Special Handling |
|---------|-----------------|
| S3 | Spaces encoded as `%20` in path; full body hash required |
| Transcribe | Includes `Content-Type` and `X-Amz-Target` in signed headers |
| Bedrock | Minimal signing (host + x-amz-date only); colons in model ID encoded as `%3A` in canonical URI |

---

### 3. `AWSService.swift` — AWS Operations

Handles all S3 and Transcribe operations.

#### S3 Upload (`uploadToS3`)
- Reads audio file from local URL
- URL-encodes the filename (handles spaces → `%20`)
- Signs the `PUT` request with SigV4
- Retries up to 3 times on network errors (non-network errors fail immediately)
- Returns the S3 URI: `s3://bucket/filename`

#### Start Transcription Job (`startTranscriptionJob`)
- Posts to `https://transcribe.{region}.amazonaws.com/` with `X-Amz-Target: Transcribe.StartTranscriptionJob`
- Passes S3 URI, language code (`en-US`), and media format (`mp4`)
- Job name is unique per recording (timestamp-based)

#### Poll Transcription Job (`pollTranscriptionJob`)
- Polls every 10 seconds, up to 60 attempts (10 minutes max)
- On `COMPLETED`: fetches the transcript JSON from the result URI and extracts the text
- On `FAILED`: throws with the failure reason
- Calls `onProgress` callback on each poll tick for live UI updates

#### List / Delete Jobs
- `listTranscriptionJobs` — fetches completed jobs for the history view
- `deleteTranscriptionJob` + `deleteFromS3` — removes both the transcript job and the source audio file together

---

### 4. `BedrockService.swift` — AI Operations

Calls AWS Bedrock's Claude model for both summarisation and chat.

#### Summarise (`summarize`)
Sends the full transcript with a structured prompt requesting:
- Overview (2–3 sentences)
- Key discussion points
- Decisions made
- Action items with owners
- Next steps

Uses `max_tokens: 2048` to allow detailed summaries.

#### Chat (`chat`)
Sends the transcript + user question in a single prompt. The prompt intentionally keeps it simple — Claude decides whether to use the transcript or answer from general knowledge. This avoids over-constraining the model.

Uses `max_tokens: 1024` for chat responses.

**Bedrock API format (Anthropic Messages API):**
```json
{
  "anthropic_version": "bedrock-2023-05-31",
  "max_tokens": 2048,
  "messages": [
    { "role": "user", "content": "<prompt>" }
  ]
}
```

---

### 5. `TranscriptCache.swift` — Local Caching

Persists transcripts to the app's Documents directory to avoid redundant AWS Transcribe calls (which cost $0.024/minute).

- **Location:** `Documents/TranscriptCache/<filename>.txt`
- **Key:** sanitised filename (spaces/slashes → underscores)
- **Singleton:** `TranscriptCache.shared`
- **Flow:** Before uploading to S3, `ContentView` checks the cache. If a transcript exists locally, it skips S3 upload and Transcribe entirely and goes straight to Bedrock for summarisation.

**Cost savings:**
| Step skipped | Saving |
|---|---|
| S3 upload | $0.005/1000 requests |
| AWS Transcribe | $0.024/minute of audio |
| Bedrock | Still called (summary may differ) |

---

### 6. UI Layer

#### `ContentView.swift` — Main Screen
The primary coordinator. Manages app state via `@State` and drives the full recording/upload/transcribe/summarise pipeline.

**Key states:**
```swift
enum ProcessingStatus {
    case idle
    case recording
    case processing   // uploading + transcribing + summarising
    case completed
    case error(String)
}
```

**Pipeline on record/import:**
```
1. Record audio OR pick file from Files app
2. Check TranscriptCache (skip to step 5 if hit)
3. Upload to S3
4. Start Transcribe job
5. Poll until COMPLETED (with live progress updates)
6. Save transcript to cache
7. Call Bedrock for summary
8. Display summary + enable Chat button
```

#### `AudioRecorder.swift`
Wraps `AVAudioRecorder`. Records to a temp `.m4a` file in the app's Documents directory. Uses `AVAudioSession` with `.record` category.

#### `AudioFilePicker.swift`
Wraps `UIDocumentPickerViewController` to let users import audio files from the Files app. Supports M4A, MP3, WAV, and other formats. Copies the selected file to a local temp path before uploading.

#### `ChatView.swift`
Presents a conversational interface over the loaded transcript. Each message is sent to `BedrockService.chat()` — transcript is included in every request (no conversation history maintained across sessions — see TODO).

#### `MeetingHistoryView.swift` / `TranscribeJobsView.swift`
Browse past transcription jobs from AWS Transcribe. Tap a job to load its transcript. Swipe left or tap the trash icon to delete both the job and the S3 audio file.

#### `SummaryDetailView.swift`
Full-screen summary view with share sheet integration (`UIActivityViewController`) for exporting to Notes, Mail, Messages, etc.

---

### 7. Data Persistence

| Data | Storage |
|------|---------|
| Meeting summaries | Core Data (`MeetingSummary` entity) |
| Transcripts | Local file cache (`TranscriptCache`) |
| Uploaded file deduplication | `@AppStorage` (JSON-encoded `Set<String>`) |
| AWS credentials | `Config.swift` (local only, gitignored) |

---

## Data Flow Diagrams

### Recording a New Meeting
```
User taps Record
      │
      ▼
AVAudioRecorder → .m4a file in Documents/
      │
      ▼
Check TranscriptCache ──► HIT → skip to Bedrock
      │ MISS
      ▼
Upload .m4a → S3 (PUT, SigV4 signed)
      │
      ▼
StartTranscriptionJob (AWS Transcribe)
      │
      ▼
Poll GetTranscriptionJob every 10s (max 60x)
      │ COMPLETED
      ▼
Fetch transcript JSON → extract text
      │
      ▼
Save to TranscriptCache
      │
      ▼
BedrockService.summarize() → Claude Haiku 4.5
      │
      ▼
Display summary + enable Chat
```

### Importing a Local Audio File
```
User taps "Load Local Audio File"
      │
      ▼
UIDocumentPickerViewController
      │
      ▼
Copy file to local temp path
      │
      ▼
Same pipeline as recording (from cache check onward)
```

### Chat Flow
```
User types question
      │
      ▼
BedrockService.chat(transcript, question)
      │
      ▼
Single prompt: transcript + question → Claude
      │
      ▼
Display response in chat bubble
```

---

## AWS SigV4 — Common Pitfalls

These were discovered during development (see `LESSONS_LEARNED.md` for full context):

1. **Bedrock model IDs contain colons** (e.g., `v1:0`) — must be percent-encoded as `%3A` in the canonical URI
2. **S3 filenames with spaces** — must be encoded as `%20`, never `+`
3. **Transcribe X-Amz-Target format** — must be `Transcribe.StartTranscriptionJob`, not `AWSTranscribe.StartTranscriptionJob`
4. **Bedrock uses minimal signing** — only `host` and `x-amz-date` in signed headers; other services require more

---

## Security

- AWS credentials stored locally in `Config.swift` (gitignored)
- All API calls use HTTPS + SigV4 signing
- Pre-commit security scanning via [AWS ASH](https://github.com/awslabs/automated-security-helper)
- ASH config in `.ash/ash.yaml` suppresses the local credential file from scanning

---

## Dependencies

No external Swift packages. All AWS integration is hand-rolled.

| Framework | Usage |
|-----------|-------|
| SwiftUI | UI layer |
| AVFoundation | Audio recording, file handling |
| CryptoKit | SHA256, HMAC for SigV4 |
| Core Data | Meeting history persistence |
| Foundation | Networking (URLSession), JSON |

---

## Configuration Reference

| Key | Description |
|-----|-------------|
| `awsAccessKey` | IAM user access key ID |
| `awsSecretKey` | IAM user secret access key |
| `awsRegion` | AWS region (e.g., `eu-west-1`) |
| `s3Bucket` | S3 bucket name for audio storage |
| `bedrockModel` | Bedrock model ID (Claude Haiku by default) |

---

## IAM Permissions Required

```json
{
  "Effect": "Allow",
  "Action": [
    "s3:PutObject",
    "s3:GetObject",
    "s3:DeleteObject",
    "transcribe:StartTranscriptionJob",
    "transcribe:GetTranscriptionJob",
    "transcribe:ListTranscriptionJobs",
    "transcribe:DeleteTranscriptionJob",
    "bedrock:InvokeModel"
  ],
  "Resource": "*"
}
```
