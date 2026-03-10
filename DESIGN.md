# Meeting Summarizer — Technical Design Document

**Version:** 1.0  
**Last Updated:** March 2026  
**Status:** Released  

---

## Table of Contents

1. [Overview](#1-overview)
2. [System Architecture](#2-system-architecture)
3. [Module Breakdown](#3-module-breakdown)
4. [Data Flows](#4-data-flows)
5. [AWS Integration](#5-aws-integration)
6. [State Management](#6-state-management)
7. [Local Persistence](#7-local-persistence)
8. [Security Model](#8-security-model)
9. [Error Handling](#9-error-handling)
10. [Known Limitations & Future Work](#10-known-limitations--future-work)
11. [Configuration Reference](#11-configuration-reference)
12. [IAM Permissions](#12-iam-permissions)

---

## 1. Overview

Meeting Summarizer is a native iOS application that records or imports audio, transcribes it using AWS Transcribe, and generates AI-powered meeting summaries and interactive Q&A using AWS Bedrock (Claude Haiku 4.5).

### Design Goals

| Goal | Decision |
|------|----------|
| No third-party SDKs | All AWS integration hand-rolled using `URLSession` + `CryptoKit` |
| Cost efficiency | Local transcript cache eliminates redundant Transcribe API calls |
| Offline-resilient data | Transcripts persisted to device filesystem; summaries in Core Data |
| Minimal footprint | No CocoaPods, no SPM packages — pure Swift/SwiftUI |

### Technology Stack

| Layer | Technology |
|-------|-----------|
| UI | SwiftUI |
| Audio | AVFoundation (AVAudioRecorder, AVAudioSession) |
| Networking | URLSession (async/await) |
| Request Signing | CryptoKit (SHA256, HMAC) |
| Local Storage | Core Data + FileManager |
| AI | AWS Bedrock — Claude Haiku 4.5 (`eu.anthropic.claude-haiku-4-5-20251001-v1:0`) |
| Transcription | AWS Transcribe |
| File Storage | AWS S3 |

---

## 2. System Architecture

### High-Level Diagram

```
┌──────────────────────────────────────────────────────────────────┐
│                          iOS Application                         │
│                                                                  │
│  ┌─────────────────────────────────────────────────────────────┐ │
│  │                      View Layer (SwiftUI)                   │ │
│  │                                                             │ │
│  │  ContentView ──► SummaryDetailView                          │ │
│  │       │                                                     │ │
│  │       ├──► ChatView                                         │ │
│  │       ├──► TranscribeJobsView                               │ │
│  │       └──► AudioFilePicker                                  │ │
│  └───────────────────────┬─────────────────────────────────────┘ │
│                          │ delegates / async calls               │
│  ┌───────────────────────▼─────────────────────────────────────┐ │
│  │                    Service Layer                            │ │
│  │                                                             │ │
│  │   AWSService          BedrockService       AudioRecorder    │ │
│  │   (S3, Transcribe)    (Claude Haiku 4.5)   (AVFoundation)   │ │
│  └───────────────────────┬─────────────────────────────────────┘ │
│                          │                                       │
│  ┌───────────────────────▼─────────────────────────────────────┐ │
│  │                  Infrastructure Layer                       │ │
│  │                                                             │ │
│  │      AWSSigV4              TranscriptCache    Core Data     │ │
│  │   (request signing)        (filesystem)       (summaries)  │ │
│  └───────────────────────┬─────────────────────────────────────┘ │
└──────────────────────────┼───────────────────────────────────────┘
                           │ HTTPS + AWS SigV4
           ┌───────────────▼──────────────────┐
           │         AWS (eu-west-1)           │
           │                                  │
           │  S3 → Transcribe → Bedrock        │
           └──────────────────────────────────┘
```

### Layer Responsibilities

**View Layer** — SwiftUI views. No business logic. Delegates all async work to services via `Task { }` blocks. Observes state changes via `@State` / `@StateObject`.

**Service Layer** — Stateless classes that own all AWS communication. Called directly from views. Each service is instantiated with credentials from `Config`.

**Infrastructure Layer** — Cross-cutting concerns: request signing (`AWSSigV4`), local caching (`TranscriptCache`), and persistence (`Core Data`). No AWS knowledge in this layer.

---

## 3. Module Breakdown

### 3.1 `Config.swift` — Runtime Configuration

Holds all environment-specific constants as a Swift `enum` (no instances). This file is excluded from source control via `.gitignore`. Each developer maintains their own local copy.

```swift
enum Config {
    static let awsAccessKey = "YOUR_AWS_ACCESS_KEY"  // pragma: allowlist secret
    static let awsSecretKey = "YOUR_AWS_SECRET_KEY"  // pragma: allowlist secret
    static let awsRegion    = "eu-west-1"
    static let s3Bucket     = "your-s3-bucket-name"
    static let bedrockModel = "eu.anthropic.claude-haiku-4-5-20251001-v1:0"
}
```

> **Note on `bedrockModel`:** In `eu-west-1`, Claude models must be accessed via cross-region inference profiles (prefixed `eu.`). Direct model IDs (e.g. `anthropic.claude-3-haiku-*`) are not accepted in this region for newer models.

---

### 3.2 `AWSSigV4.swift` — Request Signing

Implements the full [AWS Signature Version 4](https://docs.aws.amazon.com/general/latest/gr/signature-version-4.html) signing algorithm using Apple's `CryptoKit`. No AWS SDK dependency.

#### Signing Algorithm

```
Step 1 — Canonical Request
  METHOD \n
  canonical_uri \n          ← URL-encoded path (service-specific rules apply)
  canonical_query \n
  canonical_headers \n      ← lowercase header names, sorted
  signed_headers \n
  hex(SHA256(body))

Step 2 — String to Sign
  "AWS4-HMAC-SHA256" \n
  <ISO8601 datetime> \n
  <date>/<region>/<service>/aws4_request \n
  hex(SHA256(canonical_request))

Step 3 — Derive Signing Key
  kDate    = HMAC-SHA256("AWS4" + secretKey, date)
  kRegion  = HMAC-SHA256(kDate, region)
  kService = HMAC-SHA256(kRegion, service)
  kSigning = HMAC-SHA256(kService, "aws4_request")

Step 4 — Sign
  signature = hex(HMAC-SHA256(kSigning, string_to_sign))

Step 5 — Authorization Header
  AWS4-HMAC-SHA256 Credential=<key>/<scope>, SignedHeaders=<headers>, Signature=<sig>
```

#### Service-Specific Behaviour

Each AWS service has quirks that require special handling in the canonical request:

| Service | Signed Headers | Path Encoding | Special Notes |
|---------|---------------|---------------|---------------|
| **S3** | `content-type`, `host`, `x-amz-content-sha256`, `x-amz-date` | Spaces → `%20` (never `+`) | Full body SHA256 hash required in header |
| **Transcribe** | `content-type`, `host`, `x-amz-content-sha256`, `x-amz-date`, `x-amz-target` | Standard | `X-Amz-Target` header must be included in signature |
| **Bedrock** | `host`, `x-amz-date` | Colons → `%3A` | Model IDs contain `:` (e.g. `v1:0`) — must be percent-encoded in canonical URI |

---

### 3.3 `AWSService.swift` — S3 and Transcribe Operations

Handles the two AWS services that form the transcription pipeline.

#### S3 Upload (`uploadToS3`)

```
Input:  Local file URL
Output: S3 URI (s3://bucket/key)

1. Read file bytes from disk
2. URL-encode filename (spaces → %20)
3. Build PUT request to https://{bucket}.s3.{region}.amazonaws.com/{key}
4. Sign with AWSSigV4 (service: "s3")
5. Execute with URLSession
6. Retry up to 3× on network errors; fail immediately on non-network errors
7. Return "s3://{bucket}/{key}"
```

**Audio format:** Files are uploaded as `audio/mp4` (`.m4a` container). AWS Transcribe accepts this natively.

**Retry policy:**
- Network errors (`notConnectedToInternet`, `networkConnectionLost`) → retry with 2s delay
- All other errors (auth, S3 errors) → fail immediately, no retry

#### Start Transcription Job (`startTranscriptionJob`)

Posts to the Transcribe JSON API via `X-Amz-Target: Transcribe.StartTranscriptionJob`. Job names follow the pattern `meeting-{unix_timestamp}` for recordings and `local-{unix_timestamp}` for imported files.

Request body:
```json
{
  "TranscriptionJobName": "meeting-1741123456",
  "LanguageCode": "en-US",
  "MediaFormat": "mp4",
  "Media": { "MediaFileUri": "s3://bucket/filename.m4a" }
}
```

#### Poll Transcription Job (`pollTranscriptionJob`)

Polls `Transcribe.GetTranscriptionJob` every **10 seconds**, up to **60 attempts** (10-minute maximum). On each tick, calls an `onProgress` closure to push live status text to the UI.

```
COMPLETED → fetch transcript JSON from TranscriptFileUri → extract text
FAILED    → throw AWSError.transcribeFailed with FailureReason
timeout   → throw AWSError.timeout after 60 attempts
```

The transcript JSON returned by AWS has this structure:
```json
{
  "results": {
    "transcripts": [{ "transcript": "The full meeting text..." }]
  }
}
```

#### List / Delete Operations

- `listTranscriptionJobs` — fetches up to 50 `COMPLETED` jobs, maps to `TranscriptionJob` model
- `deleteTranscriptionJob` — calls `Transcribe.DeleteTranscriptionJob`
- `deleteFromS3(key:)` — HTTP `DELETE` to S3 object URL, expects `204 No Content`

Both delete operations are always called together — deleting a job without its source audio would leave orphaned S3 objects.

---

### 3.4 `BedrockService.swift` — AI Summarisation and Chat

Calls the Bedrock Runtime API using the [Anthropic Messages API](https://docs.aws.amazon.com/bedrock/latest/userguide/model-parameters-anthropic-claude-messages.html) format.

**Endpoint pattern:**
```
POST https://bedrock-runtime.{region}.amazonaws.com/model/{modelId}/invoke
```

**Request format:**
```json
{
  "anthropic_version": "bedrock-2023-05-31",
  "max_tokens": 2048,
  "messages": [
    { "role": "user", "content": "<prompt>" }
  ]
}
```

**Response extraction:**
```swift
json["content"][0]["text"] // → the AI response string
```

#### Summarise (`summarize`)

Uses a structured prompt that instructs Claude to produce five sections: Overview, Key Discussion Points, Decisions Made, Action Items, and Next Steps. `max_tokens: 2048` allows detailed output for long meetings.

#### Chat (`chat`)

Sends the full transcript + user question in a single prompt on every call. The prompt is intentionally minimal — no strict rules about when to use the transcript vs. general knowledge. This avoids the common failure mode of over-constraining the model (see `LESSONS_LEARNED.md` §9).

> **Known limitation:** Chat history is not maintained across turns. Each question is independent; Claude has no memory of previous questions in the session. See [§10](#10-known-limitations--future-work).

---

### 3.5 `AudioRecorder.swift` — Audio Capture

Wraps `AVAudioRecorder` as an `ObservableObject` for SwiftUI integration.

**Session configuration:**
- Category: `.record` (silences playback during recording)
- Mode: `.default`
- Activated/deactivated on start/stop

**Recording settings:**
| Setting | Value | Rationale |
|---------|-------|-----------|
| Format | `kAudioFormatMPEG4AAC` | AWS Transcribe accepts natively; good compression |
| Sample Rate | 16,000 Hz | Minimum for accurate speech recognition |
| Channels | 1 (mono) | Reduces file size; Transcribe doesn't need stereo |
| Quality | `.high` | Maximises transcription accuracy |

**Output:** Timestamped `.m4a` file in `FileManager.default.temporaryDirectory`.

---

### 3.6 `AudioFilePicker.swift` — File Import

Wraps `UIDocumentPickerViewController` as a `UIViewControllerRepresentable`. Allows importing audio files from the Files app, Voice Memos, iCloud Drive, or any connected storage.

The picker dismisses immediately on file selection (before processing begins) to avoid the UX issue of the picker remaining visible while the app is working.

---

### 3.7 `TranscriptCache.swift` — Local Caching

Persists raw transcript text to the app's Documents directory to avoid redundant AWS Transcribe calls.

**Cache key derivation:**
```swift
fileName
  .replacingOccurrences(of: " ", with: "_")
  .replacingOccurrences(of: "/", with: "_")
// → stored as Documents/TranscriptCache/{key}.txt
```

**Cache lifecycle:**
```
processLocalAudio(url)
    │
    ├─► TranscriptCache.loadTranscript(for: fileName)
    │       │
    │       ├─ HIT  → skip S3 + Transcribe, go straight to Bedrock
    │       │          (saves ~$0.024/min in Transcribe costs)
    │       │
    │       └─ MISS → full pipeline, then saveTranscript() after completion
    │
    └─► Cache entry persists indefinitely (manual clear via clearCache())
```

---

### 3.8 View Layer

#### `ContentView.swift` — Application Shell

The root view and primary coordinator. Owns all `@State` variables and orchestrates the full pipeline via `Task { }` blocks.

**App state machine (`AppStatus` enum):**

```
idle ──► recording ──► uploading ──► transcribing ──► summarizing ──► done
 ▲                                                                      │
 └──────────────────────── error (reset) ◄──────────────────────────────┘

processing (alias for uploading, used for imported files)
```

**Key `@State` / `@AppStorage` properties:**

| Property | Type | Purpose |
|----------|------|---------|
| `status` | `AppStatus` | Drives UI state (button labels, progress steps, colours) |
| `transcript` | `String` | Holds current transcript text; enables Chat button when non-empty |
| `summary` | `String` | Holds generated summary; triggers auto-scroll when first set |
| `logs` | `[String]` | In-app debug log with timestamp prefix |
| `transcriptionProgress` | `String` | Live poll status from `pollTranscriptionJob` callback |
| `uploadedFiles` | `Set<String>` via `@AppStorage` | Deduplication guard; persists across app launches |

**Auto-scroll behaviour:**
When `summary` transitions from empty to non-empty, the view scrolls to the summary card with a 0.3s delay and 0.5s ease-in-out animation. The delay prevents the scroll from firing before layout is complete.

#### `ChatView.swift` — Conversational Interface

Presents a standard chat UI with user/assistant message bubbles. Messages are stored in `[ChatMessage]` local state — not persisted.

**`ChatMessage` model:**
```swift
struct ChatMessage: Identifiable {
    let id: UUID        // List identity
    let text: String
    let isUser: Bool
    let isSystem: Bool  // Shown in orange; used for the opening greeting
    let timestamp: Date // Displayed as time label under each bubble
}
```

Long-pressing an AI message reveals a copy button (animated in/out).

#### `TranscribeJobsView.swift` — Job History Browser

Fetches and displays `COMPLETED` Transcribe jobs from AWS on appear. Supports:
- Tap to load transcript (fetches URI then full text — two API calls)
- Swipe-to-delete or trash icon — deletes job + S3 audio with confirmation alert
- Pull-to-refresh via toolbar button

#### `SummaryDetailView.swift` — Full Summary + Export

Full-screen summary with `textSelection(.enabled)` for user text selection. Export via `UIActivityViewController` (system share sheet) supports Notes, Mail, Messages, Files, etc.

---

## 4. Data Flows

### 4.1 Record New Meeting

```
User taps record button
        │
        ▼
AVAudioRecorder.startRecording()
  → category: .record, sample rate: 16kHz, mono, AAC
  → writes to tmp/meeting-{timestamp}.m4a
        │
User taps stop
        │
        ▼
processRecording()
        │
        ├─► status = .uploading
        │   AWSService.uploadToS3(fileURL)
        │     → PUT https://bucket.s3.eu-west-1.amazonaws.com/meeting-{ts}.m4a
        │     → SigV4 signed, retry ×3 on network error
        │     → returns "s3://bucket/meeting-{ts}.m4a"
        │
        ├─► status = .transcribing
        │   AWSService.startTranscriptionJob(s3URI, jobName: "meeting-{ts}")
        │     → POST Transcribe.StartTranscriptionJob
        │
        │   AWSService.pollTranscriptionJob(jobName)
        │     → poll every 10s, max 60 attempts
        │     → onProgress callback → transcriptionProgress @State → UI label
        │     → COMPLETED: fetch transcript JSON → extract text string
        │
        ├─► status = .summarizing
        │   BedrockService.summarize(transcript)
        │     → POST bedrock-runtime.eu-west-1.amazonaws.com/model/{id}/invoke
        │     → SigV4 signed (minimal: host + x-amz-date only)
        │     → returns structured summary string
        │
        └─► status = .done
            summary @State set → triggers auto-scroll to summary card
            transcript @State set → Chat button appears
```

### 4.2 Import Local Audio File (with Cache Hit)

```
User taps "Load Local Audio File"
        │
        ▼
UIDocumentPickerViewController presented
        │
User selects file → picker dismissed immediately
        │
        ▼
processLocalAudio(fileURL)
        │
        ▼
TranscriptCache.loadTranscript(for: fileName)
        │
        ├─ HIT ──► transcript loaded from Documents/TranscriptCache/{key}.txt
        │          status = .summarizing
        │          BedrockService.summarize(transcript)
        │          status = .done
        │          [S3 upload and Transcribe completely skipped]
        │
        └─ MISS ──► full pipeline (same as recording flow above)
                    + TranscriptCache.saveTranscript() after poll completes
```

### 4.3 Chat with Transcript

```
User types question → taps send
        │
        ▼
ChatMessage(isUser: true) appended to messages[]
isLoading = true
        │
        ▼
BedrockService.chat(transcript: transcript, question: question)
  → Full transcript + question sent in single prompt
  → POST to Bedrock (same endpoint as summarize)
  → max_tokens: 1024
        │
        ▼
ChatMessage(isUser: false) appended with AI response
isLoading = false
ScrollView auto-scrolls to latest message
```

### 4.4 Load from AWS History

```
User taps "Load from AWS Transcribe"
        │
        ▼
TranscribeJobsView.task { loadJobs() }
  → POST Transcribe.ListTranscriptionJobs (status: COMPLETED, max: 50)
  → maps response to [TranscriptionJob]
        │
User taps a job
        │
        ▼
selectJob(job)
  1. POST Transcribe.GetTranscriptionJob → extract TranscriptFileUri
  2. GET TranscriptFileUri (S3 pre-signed URL) → fetch JSON
  3. Extract transcript text → pass back via @Binding selectedTranscript
        │
        ▼
ContentView.onChange(selectedTranscript)
  → loadTranscript() → BedrockService.summarize()
```

---

## 5. AWS Integration

### 5.1 Service Endpoints

| Service | Endpoint Pattern | Protocol |
|---------|-----------------|----------|
| S3 | `https://{bucket}.s3.{region}.amazonaws.com/{key}` | REST (PUT/DELETE) |
| Transcribe | `https://transcribe.{region}.amazonaws.com/` | JSON RPC via `X-Amz-Target` |
| Bedrock Runtime | `https://bedrock-runtime.{region}.amazonaws.com/model/{id}/invoke` | REST (POST) |

### 5.2 Transcribe API — Target Headers

AWS Transcribe uses an older JSON-RPC style API where the operation is specified via an HTTP header rather than the URL path:

| Operation | X-Amz-Target |
|-----------|-------------|
| Start job | `Transcribe.StartTranscriptionJob` |
| Get job | `Transcribe.GetTranscriptionJob` |
| List jobs | `Transcribe.ListTranscriptionJobs` |
| Delete job | `Transcribe.DeleteTranscriptionJob` |

> ⚠️ The prefix is `Transcribe.` — not `AWSTranscribe.`. This is a common source of `UnknownOperationException` errors.

### 5.3 Bedrock Model — Cross-Region Inference

In `eu-west-1`, newer Claude models must be accessed via **cross-region inference profiles** — direct model IDs return `ValidationException`.

| Model | Direct ID (❌ fails in eu-west-1) | Inference Profile (✅ works) |
|-------|----------------------------------|------------------------------|
| Claude Haiku 4.5 | `anthropic.claude-haiku-4-5-20251001-v1:0` | `eu.anthropic.claude-haiku-4-5-20251001-v1:0` |

The `eu.` prefix routes the request through AWS's cross-region inference infrastructure, which selects an appropriate backend region automatically.

### 5.4 Cost Profile

Estimated cost per meeting (30-minute audio):

| Service | Operation | Unit Cost | Per Meeting |
|---------|-----------|-----------|-------------|
| S3 | PUT (upload) | $0.005/1000 req | ~$0.000005 |
| S3 | Storage | $0.023/GB/month | ~$0.00003 |
| Transcribe | Transcription | $0.024/min | ~$0.72 |
| Bedrock | Input tokens (~2000) | $0.001/1000 tokens | ~$0.002 |
| Bedrock | Output tokens (~500) | $0.005/1000 tokens | ~$0.003 |
| **Total** | | | **~$0.73** |

**Cache impact:** On a cache hit, Transcribe ($0.72) is skipped entirely — cost drops to ~$0.005 per repeated processing of the same file.

---

## 6. State Management

The app uses standard SwiftUI state primitives — no external state management library.

| Primitive | Used For |
|-----------|----------|
| `@State` | View-local transient state (transcript text, logs, progress, UI flags) |
| `@StateObject` | `AudioRecorder` — owned by `ContentView`, persists across re-renders |
| `@Binding` | Passing `selectedTranscript` from `TranscribeJobsView` back to `ContentView` |
| `@AppStorage` | `uploadedFiles` — persists `Set<String>` of uploaded filenames across launches |
| `@Environment(\.dismiss)` | Sheet dismissal in modal views |

### Why No ViewModel?

The app's interaction model is linear (record → upload → transcribe → summarise → display) with a single primary screen. A dedicated ViewModel layer would add boilerplate without meaningful benefit at this scale. `ContentView` acts as a lightweight coordinator.

---

## 7. Local Persistence

### Transcript Cache

- **Location:** `<Documents>/TranscriptCache/<key>.txt`
- **Lifetime:** Permanent until `clearCache()` is called
- **Thread safety:** File operations are synchronous but called only from `async` Task contexts — safe in practice, not formally synchronized

### Uploaded Files Registry

- **Mechanism:** `@AppStorage("uploadedFiles")` stores a JSON-encoded `Set<String>`
- **Purpose:** Prevents re-uploading the same file to S3 on subsequent imports
- **Limitation:** Keyed by filename only — renamed copies of the same audio will upload again

### Core Data

Core Data is included in the project (via Xcode template) and the `MeetingSummarizerApp` sets up a `PersistenceController`. Meeting summary storage to Core Data is not yet fully wired up in the current release — summaries live in `@State` only and are lost on app close.

---

## 8. Security Model

### Credential Storage

AWS credentials (`accessKey`, `secretKey`) are stored in `Config.swift`, which is:
- Listed in `.gitignore` — never committed to source control
- Present only on the developer's local machine / build machine
- Not encrypted at rest (stored as plaintext Swift constants)

> **For production deployment**, credentials should be moved to AWS Cognito Identity Pools (federated identity) or loaded from an encrypted keychain entry at runtime. Hardcoded keys are acceptable for personal/demo use only.

### Request Security

All AWS API calls use:
- **HTTPS** (TLS 1.2+, enforced by iOS ATS)
- **AWS SigV4** signatures — requests cannot be replayed or tampered with; signatures expire after 15 minutes

### Secret Scanning

Pre-commit hooks run [AWS Automated Security Helper (ASH)](https://github.com/awslabs/automated-security-helper) via `detect-secrets` on every commit. `Config.swift` is excluded from scanning (local only). See `.ash/ash.yaml` for suppression configuration.

---

## 9. Error Handling

### Error Types

```swift
enum AWSError: Error, LocalizedError {
    case uploadFailed       // S3 PUT returned non-200, or file unreadable
    case transcribeFailed   // Job returned FAILED status, or API error
    case timeout            // 60 poll attempts exceeded (10 minutes)
}

enum BedrockError: Error, LocalizedError {
    case invocationFailed(String)  // Non-200 response; message contains body
    case invalidResponse           // Response JSON missing expected fields
}
```

### Error Propagation

All async operations throw and propagate up to the `processRecording()` / `processLocalAudio()` call sites in `ContentView`, where they are caught and displayed via SwiftUI `.alert()`. The `addLog()` function also captures error messages with timestamps for in-app debugging.

### Retry Policy

Only S3 uploads implement retry (network errors only, max 3 attempts, 2s delay). Transcribe and Bedrock calls fail immediately on error — the user must retry the full pipeline manually.

---

## 10. Known Limitations & Future Work

| Priority | Area | Current State | Planned Improvement |
|----------|------|--------------|---------------------|
| 🔴 High | **Credential security** | Hardcoded in `Config.swift` | Migrate to AWS Cognito Identity Pools |
| ✅ Done | **Background processing** | Saves job name on start; resumes polling on app reopen | Implemented |
| ✅ Done | **Cancel processing** | Cancel button stops pipeline, releases microphone, resets UI | Implemented |
| 🔴 High | **Transcription polling** | Fixed 10s interval, 60 attempts max | Exponential backoff; better timeout UX |
| 🟡 Medium | **Chat history** | Not persisted; resets each session | Save conversation per meeting to Core Data |
| 🟡 Medium | **Core Data summaries** | Not fully wired | Persist summaries across app launches |
| 🟡 Medium | **Language support** | English (`en-US`) only | Language picker (AWS Transcribe supports 30+) |
| 🟡 Medium | **Speaker diarization** | Not implemented | AWS Transcribe supports "who said what" |
| 🟢 Low | **Export formats** | Plain text share sheet only | PDF export with formatted layout |
| 🟢 Low | **iCloud sync** | Device-local only | Sync transcripts/summaries via CloudKit |
| 🟢 Low | **Offline transcription** | Not available | Local speech-to-text (iOS 17 `SFSpeechRecognizer`) |

---

## 11. Configuration Reference

| Key | Type | Description |
|-----|------|-------------|
| `awsAccessKey` | `String` | IAM user Access Key ID |
| `awsSecretKey` | `String` | IAM user Secret Access Key |
| `awsRegion` | `String` | AWS region (e.g. `eu-west-1`) |
| `s3Bucket` | `String` | S3 bucket name for audio file storage |
| `bedrockModel` | `String` | Bedrock inference profile ID — must use `eu.` prefix in `eu-west-1` |

---

## 12. IAM Permissions

Minimum IAM policy required for the app to function:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "S3AudioStorage",
      "Effect": "Allow",
      "Action": [
        "s3:PutObject",
        "s3:GetObject",
        "s3:DeleteObject"
      ],
      "Resource": "arn:aws:s3:::YOUR_BUCKET_NAME/*"
    },
    {
      "Sid": "TranscribeOperations",
      "Effect": "Allow",
      "Action": [
        "transcribe:StartTranscriptionJob",
        "transcribe:GetTranscriptionJob",
        "transcribe:ListTranscriptionJobs",
        "transcribe:DeleteTranscriptionJob"
      ],
      "Resource": "*"
    },
    {
      "Sid": "BedrockInference",
      "Effect": "Allow",
      "Action": [
        "bedrock:InvokeModel"
      ],
      "Resource": "arn:aws:bedrock:eu-west-1::foundation-model/anthropic.claude-haiku-4-5-20251001-v1:0"
    }
  ]
}
```

> **Security tip:** Scope the S3 resource to your specific bucket ARN (not `*`) to follow the principle of least privilege.
