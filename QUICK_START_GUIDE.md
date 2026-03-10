# Quick Start Guide

## Main Screen Features

### 1. Record a Meeting
- Tap the big blue/red circle button
- Speak into your iPhone
- Tap again to stop
- App automatically uploads, transcribes, and summarizes

### 2. Load from AWS Transcribe
- Tap "Load from AWS Transcribe" button
- See all your previous transcription jobs
- Tap any completed job to load its transcript
- **DELETE**: Tap the red trash icon or swipe left

### 3. Load Local Audio File (NEW!)
- Tap "Load Local Audio File" button
- Browse your iPhone files
- Select any audio file (Voice Memos, recordings, etc.)
- App uploads, transcribes, and summarizes automatically

### 4. Chat with AI (NEW!)
- After loading a transcript, tap "Chat with AI about transcript"
- Ask questions like:
  - "What were the action items?"
  - "Who is responsible for the database?"
  - "Summarize the marketing discussion"
- Get instant AI-powered answers

### 5. View Summary
- Tap the summary preview to see full text
- Use the menu (•••) to:
  - Copy to clipboard
  - Share to Notes, Messages, Mail, etc.

---

## Common Workflows

### Workflow 1: Record New Meeting
```
1. Tap record button
2. Record your meeting
3. Tap stop
4. Wait for transcription (shows progress)
5. View summary
6. Tap "Chat with AI" to ask questions
7. Export summary to Notes
```

### Workflow 2: Upload Voice Memo
```
1. Record voice memo in Voice Memos app
2. Open Meeting Summarizer app
3. Tap "Load Local Audio File"
4. Select your voice memo
5. Wait for processing
6. View summary and chat with AI
```

### Workflow 3: Review Old Meeting
```
1. Tap "Load from AWS Transcribe"
2. Browse your past meetings
3. Tap one to load
4. View summary
5. Chat with AI to ask specific questions
6. Export if needed
```

### Workflow 4: Clean Up Old Meetings
```
1. Tap "Load from AWS Transcribe"
2. Find meetings you don't need
3. Tap red trash icon (or swipe left)
4. Confirm deletion
5. Both transcript and audio file deleted from AWS
```

---

## Tips

- **Voice Memos**: The app works great with iPhone Voice Memos (M4A format)
- **Chat**: Ask specific questions to get better answers
- **Delete**: Deleting removes BOTH the transcript and audio file
- **Logs**: Check in-app logs if something goes wrong
- **Export**: Use share button to save summaries to Notes for later

---

## Troubleshooting

**"No transcription jobs found"**
→ You haven't recorded or uploaded any meetings yet

**Delete button doesn't work**
→ Make sure IAM permissions are updated (see IAM_POLICY_UPDATE.md)

**Chat button doesn't appear**
→ You need to load or record a transcript first

**File picker shows no files**
→ Try recording a voice memo first, or check Files app

**Upload fails**
→ Check internet connection and AWS credentials

---

## What Each Button Does

| Button | What It Does |
|--------|-------------|
| 🔴 Record | Record new meeting audio |
| ☁️ Load from AWS | View and load past transcriptions |
| 📁 Load Local Audio | Pick audio file from iPhone |
| 💬 Chat with AI | Ask questions about transcript |
| 🗑️ Trash Icon | Delete transcription and audio |
| ↗️ View Full | Open full summary with export |

---

## Next Steps

1. Build and run the app in Xcode
2. Try recording a short test meeting
3. Test the chat feature
4. Try uploading a voice memo
5. Practice deleting old transcriptions

Enjoy your AI-powered meeting assistant!
