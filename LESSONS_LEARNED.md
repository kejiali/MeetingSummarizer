# Lessons Learned - Meeting Summarizer Development

This document captures all the errors, fixes, and lessons learned during the development of the Meeting Summarizer iOS app.

---

## 1. AWS SigV4 Signature Issues

### Problem: Bedrock API returning 403 "Signature Does Not Match"

**Error:**
```
The request signature we calculated does not match the signature you provided.
Canonical URI should be: /model/anthropic.claude-3-haiku-20240307-v1%3A0/invoke
```

**Root Cause:**
- AWS SigV4 requires colons (`:`) in URL paths to be percent-encoded as `%3A`
- Bedrock model IDs contain colons (e.g., `v1:0`)
- Our code wasn't encoding the colon in the canonical URI

**Fix:**
```swift
if service == "bedrock" {
    canonicalURI = canonicalURI.replacingOccurrences(of: ":", with: "%3A")
}
```

**Lesson:** AWS SigV4 signing is very strict about URL encoding. Always check AWS error messages for the expected canonical string.

---

## 2. S3 Upload Fails with Spaces in Filenames

### Problem: Files with spaces fail to upload to S3

**Error:**
```
SignatureDoesNotMatch: The request signature we calculated does not match
Canonical URI should be: /Merrion%20Crescent.m4a
```

**Root Cause:**
- Filenames with spaces need to be URL-encoded
- We were creating S3 URLs without encoding the filename
- Spaces must be encoded as `%20`, not `+`

**Fix:**
```swift
guard let encodedKey = key.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
    throw AWSError.uploadFailed
}
let s3URL = URL(string: "https://\(bucketName).s3.\(region).amazonaws.com/\(encodedKey)")
```

**Lesson:** Always URL-encode filenames before using them in URLs, especially for S3 uploads.

---

## 3. Missing IAM Permissions

### Problem: Delete operations return AccessDeniedException

**Error:**
```
User is not authorized to perform: transcribe:DeleteTranscriptionJob
User is not authorized to perform: s3:DeleteObject
```

**Root Cause:**
- IAM policy didn't include delete permissions
- Only had read/write permissions initially

**Fix:**
Added to IAM policy:
```json
{
    "Effect": "Allow",
    "Action": [
        "s3:DeleteObject",
        "transcribe:DeleteTranscriptionJob"
    ]
}
```

**Lesson:** Always plan IAM permissions for the full lifecycle (create, read, update, delete), not just initial operations.

---

## 4. Missing iOS Privacy Permissions

### Problem: App crashes when accessing Music library

**Error:**
```
This app has crashed because it attempted to access privacy-sensitive data 
without a usage description. The app's Info.plist must contain an 
NSAppleMusicUsageDescription key
```

**Root Cause:**
- iOS requires explicit permission descriptions in Info.plist
- We added Music library picker without the required permission

**Fix:**
Added to Info.plist:
```xml
<key>NSAppleMusicUsageDescription</key>
<string>This app needs access to your music library to import audio files for transcription and summarization.</string>
```

**Lesson:** Always add privacy usage descriptions BEFORE implementing features that access user data.

---

## 5. Transcribe API Wrong Target Format

### Problem: Transcribe returns UnknownOperationException

**Error:**
```
{"__type":"UnknownOperationException"}
```

**Root Cause:**
- Used wrong X-Amz-Target format: `AWSTranscribe.StartTranscriptionJob`
- Correct format: `Transcribe.StartTranscriptionJob`

**Fix:**
```swift
request.setValue("Transcribe.StartTranscriptionJob", forHTTPHeaderField: "X-Amz-Target")
```

**Lesson:** AWS service API formats vary. Always check the official AWS documentation for the exact header format.

---

## 6. Deduplication Not Working

### Problem: Same file can be uploaded multiple times

**Root Cause:**
- Used `@State` for tracking uploaded files
- State is reset when view is recreated
- Set was always empty on new uploads

**Fix:**
```swift
@AppStorage("uploadedFiles") private var uploadedFilesData: Data = Data()

private var uploadedFiles: Set<String> {
    get {
        (try? JSONDecoder().decode(Set<String>.self, from: uploadedFilesData)) ?? []
    }
}
```

**Lesson:** Use `@AppStorage` or persistent storage for data that needs to survive view recreation and app restarts.

---

## 7. Poor User Experience - No Progress Indication

### Problem: Users confused when processing local audio files

**Issues:**
- File picker doesn't dismiss after selection
- No progress bar shown
- Users don't know if anything is happening

**Fix:**
1. Dismiss file picker immediately after selection
2. Set status to `.processing` right away
3. Show progress steps with live updates
4. Add transcription polling status: "Checking status (attempt X/60)"

**Lesson:** Always provide immediate feedback when user takes an action. Never leave users wondering if something is happening.

---

## 8. Auto-Scroll Behavior Too Aggressive

### Problem: Screen jumps and shows blank areas when summary appears

**Root Cause:**
- Scrolling immediately when summary appears
- No animation delay
- Scrolling to `.top` anchor pushes content off screen

**Fix:**
```swift
.onChange(of: summary) { oldValue, newValue in
    if !newValue.isEmpty && oldValue.isEmpty {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            withAnimation(.easeInOut(duration: 0.5)) {
                proxy.scrollTo("summary", anchor: .center)
            }
        }
    }
}
```

**Lesson:** Add delays and smooth animations for auto-scroll. Use `.center` anchor for better UX.

---

## 9. AI Chat Prompt Confusion

### Problem: AI tries to answer all questions from transcript, even general ones

**Issue:**
- User asks "What LLM are you using?"
- AI responds: "The transcript does not mention a language model"

**Root Cause:**
- Overly complex prompt with too many rules
- AI overthinking when to use transcript vs general knowledge

**Fix:**
Simplified prompt:
```
You are Claude (model-id) running on AWS Bedrock. You're a helpful AI assistant.

The user has a meeting transcript. Here it is:
[transcript]

User's question: [question]

Answer naturally. If they ask about the meeting/transcript, use it. 
If they ask about you or anything else, just answer normally.
```

**Lesson:** Keep AI prompts simple and natural. Too many rules confuse the model.

---

## 10. Cost Optimization - Redundant Transcriptions

### Problem: Re-uploading same file costs money for S3 and Transcribe

**Solution:**
Implemented local transcript caching:
1. After transcription, save transcript to local storage
2. Before uploading, check if transcript exists in cache
3. If cached, skip S3 upload and transcription
4. Only run Bedrock summarization (much cheaper)

**Implementation:**
```swift
if let cachedTranscript = TranscriptCache.shared.loadTranscript(for: fileName) {
    transcript = cachedTranscript
    // Skip to summarization
}
```

**Savings:**
- S3 upload: $0.005 per 1000 requests (saved)
- Transcribe: $0.024 per minute (saved)
- Bedrock: Still needed for summarization

**Lesson:** Cache expensive API results locally. Transcripts don't change, so perfect for caching.

---

## 11. iOS Deprecation Warnings

### Problem: Using deprecated AVFoundation APIs in iOS 18

**Warnings:**
```
'init(url:)' was deprecated in iOS 18.0: Use AVURLAsset(url:) instead
'exportAsynchronously(completionHandler:)' was deprecated in iOS 18.0
```

**Fix:**
Updated to use modern async/await APIs:
```swift
let asset = AVURLAsset(url: assetURL)
await exportSession.export()
guard exportSession.status == .completed else { return }
```

**Lesson:** Keep up with iOS API changes. Use async/await for cleaner code.

---

## 12. UI Layout Issues - Content Hidden Off-Screen

### Problem: Summary and chat button not visible after processing

**Root Cause:**
- VStack with Spacer() pushes content down
- Logs view takes up too much space
- No scrolling capability

**Fix:**
Wrapped entire VStack in ScrollView:
```swift
ScrollView {
    VStack(spacing: 24) {
        // All content
    }
    .padding()
}
```

**Lesson:** Always make content scrollable when it might exceed screen height. Don't rely on fixed layouts.

---

## Key Takeaways

### AWS Integration
1. Test AWS CLI commands before implementing in code
2. AWS SigV4 signing is strict - follow exact specifications
3. Always URL-encode paths and filenames
4. Check IAM permissions for full CRUD operations

### iOS Development
1. Add privacy permissions before implementing features
2. Use `@AppStorage` for persistent data
3. Provide immediate user feedback for all actions
4. Make UIs scrollable by default
5. Test on real devices, not just simulator

### Cost Optimization
1. Cache expensive API results locally
2. Avoid redundant uploads and API calls
3. Implement deduplication early

### User Experience
1. Show progress indicators for all async operations
2. Auto-scroll should be smooth and delayed
3. Clear error messages help users understand issues
4. Test the full user flow, not just happy path

### AI Integration
1. Keep prompts simple and natural
2. Test prompts with various question types
3. Don't over-constrain AI behavior with too many rules

---

## Development Best Practices Applied

1. **Incremental Development** - Built features one at a time, tested each
2. **Error Logging** - Added comprehensive logging for debugging
3. **User Feedback** - Always show what's happening to the user
4. **Cost Awareness** - Implemented caching to reduce AWS costs
5. **Documentation** - Created guides for setup and usage
6. **Testing** - Tested with AWS CLI before implementing in Swift

---

## Future Improvements

1. Add offline mode with local speech-to-text
2. Support more audio formats
3. Add transcript editing capability
4. Implement conversation history in chat
5. Add export options (PDF, Word, etc.)
6. Support multiple languages
7. Add voice playback of summaries
8. Implement sharing between devices via iCloud

---

This document serves as a reference for future development and helps avoid repeating the same mistakes.
