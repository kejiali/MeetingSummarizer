import SwiftUI

struct ContentView: View {
    private enum PendingTranscriptionStorage {
        static let jobNameKey = "pendingTranscriptionJobName"
        static let sourceFileNameKey = "pendingTranscriptionSourceFileName"
    }

    @EnvironmentObject private var resumeState: AppResumeState
    @StateObject private var recorder = AudioRecorder()
    @State private var status: AppStatus = .idle
    @State private var transcript: String = ""
    @State private var summary: String = ""
    @State private var errorMessage: String = ""
    @State private var showError = false
    @State private var showTranscribeJobs = false
    @State private var showSummaryDetail = false
    @State private var showChat = false
    @State private var showFilePicker = false
    @State private var selectedTranscript: String?
    @State private var logs: [String] = []
    @State private var transcriptionProgress: String = ""
    @State private var processingTask: Task<Void, Never>?
    @AppStorage("uploadedFiles") private var uploadedFilesData: Data = Data()
    
    private var uploadedFiles: Set<String> {
        get {
            (try? JSONDecoder().decode(Set<String>.self, from: uploadedFilesData)) ?? []
        }
    }
    
    private func addToUploadedFiles(_ fileName: String) {
        var files = uploadedFiles
        files.insert(fileName)
        if let data = try? JSONEncoder().encode(files) {
            uploadedFilesData = data
        }
    }

    private let aws = AWSService(
        region: Config.awsRegion,
        bucketName: Config.s3Bucket,
        accessKey: Config.awsAccessKey,
        secretKey: Config.awsSecretKey
    )

    private let bedrock = BedrockService(
        region: Config.awsRegion,
        modelId: Config.bedrockModel,
        accessKey: Config.awsAccessKey,
        secretKey: Config.awsSecretKey
    )

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 24) {

                        if !resumeState.statusMessage.isEmpty {
                            Text(resumeState.statusMessage)
                                .font(.subheadline)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 6)
                                .background(Color.orange.opacity(0.15))
                                .foregroundStyle(.orange)
                                .clipShape(Capsule())
                        }

                        // Status indicator
                        statusBadge

                        // Record button
                        recordButton

                        // Load from AWS button
                        Button {
                            showTranscribeJobs = true
                        } label: {
                            Label("Load from AWS Transcribe", systemImage: "cloud.fill")
                        }
                        .buttonStyle(.bordered)
                        
                        // Load local audio button
                        Button {
                            showFilePicker = true
                        } label: {
                            Label("Load Local Audio File", systemImage: "folder.fill")
                        }
                        .buttonStyle(.bordered)

                        // Progress steps
                        if status != .idle {
                            progressSteps
                        }
                        
                        // Logs view
                        if !logs.isEmpty {
                            logsView
                        }

                        // Summary output
                        if !summary.isEmpty {
                            VStack(spacing: 16) {
                                // Success indicator
                                HStack {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                        .font(.title2)
                                    Text("Processing Complete!")
                                        .font(.headline)
                                        .foregroundStyle(.green)
                                }
                                .padding()
                                .frame(maxWidth: .infinity)
                                .background(Color.green.opacity(0.1))
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                
                                summaryPreview
                                    .id("summary")
                            }
                        }
                        
                        // Chat button
                        if !transcript.isEmpty {
                            Button {
                                showChat = true
                            } label: {
                                Label("Chat with AI about transcript", systemImage: "bubble.left.and.bubble.right.fill")
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                        }
                    }
                    .padding()
                }
                .onChange(of: summary) { oldValue, newValue in
                    if !newValue.isEmpty && oldValue.isEmpty {
                        // Only scroll when summary first appears, with a slight delay
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            withAnimation(.easeInOut(duration: 0.5)) {
                                proxy.scrollTo("summary", anchor: .center)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Meeting Summarizer")
            .alert("Error", isPresented: $showError) {
                Button("OK") { status = .idle }
            } message: {
                Text(errorMessage)
            }
            .sheet(isPresented: $showTranscribeJobs) {
                TranscribeJobsView(selectedTranscript: $selectedTranscript)
            }
            .sheet(isPresented: $showSummaryDetail) {
                SummaryDetailView(summary: summary)
            }
            .sheet(isPresented: $showChat) {
                ChatView(transcript: transcript)
            }
            .sheet(isPresented: $showFilePicker) {
                AudioFilePicker { url in
                    showFilePicker = false  // Dismiss the picker
                    processingTask = Task {
                        await processLocalAudio(url)
                    }
                }
            }
            .onChange(of: selectedTranscript) { _, newValue in
                if let transcript = newValue {
                    loadTranscript(transcript)
                }
            }
            .onChange(of: resumeState.transcript) { _, newValue in
                guard !newValue.isEmpty else { return }
                transcript = newValue
            }
            .onChange(of: resumeState.summary) { _, newValue in
                guard !newValue.isEmpty else { return }
                summary = newValue
                status = .done
                addLog("Resumed transcription completed and summarized")
            }
            .onChange(of: resumeState.errorMessage) { _, newValue in
                guard let newValue else { return }
                addLog("ERROR: \(newValue)")
                showError(message: newValue)
                resumeState.consumeErrorMessage()
            }
        }
    }

    // MARK: - Subviews

    private var statusBadge: some View {
        Text(status.label)
            .font(.subheadline)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(status.color.opacity(0.15))
            .foregroundStyle(status.color)
            .clipShape(Capsule())
    }

    private var recordButton: some View {
        Button {
            handleRecordTap()
        } label: {
            ZStack {
                Circle()
                    .fill(recorder.isRecording ? Color.red : Color.blue)
                    .frame(width: 100, height: 100)
                    .shadow(radius: 6)

                Image(systemName: recorder.isRecording ? "stop.fill" : "mic.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(.white)
            }
        }
        .disabled(status == .processing)
        .scaleEffect(recorder.isRecording ? 1.05 : 1.0)
        .animation(recorder.isRecording ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true) : .none, value: recorder.isRecording)
        .id(recorder.isRecording) // forces SwiftUI to rebuild the view and kill the animation
    }

    private var progressSteps: some View {
        VStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 10) {
                StepRow(label: "Uploading to S3",    active: status == .uploading,    done: status.rawValue > AppStatus.uploading.rawValue)
                StepRow(label: "Transcribing audio", active: status == .transcribing, done: status.rawValue > AppStatus.transcribing.rawValue)
                
                // Show transcription progress
                if status == .transcribing && !transcriptionProgress.isEmpty {
                    Text(transcriptionProgress)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 30)
                }
                
                StepRow(label: "Summarizing",        active: status == .summarizing,  done: status.rawValue > AppStatus.summarizing.rawValue)
            }
            .padding()
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))

            Button(role: .destructive) {
                cancelProcessing()
            } label: {
                Label("Cancel", systemImage: "xmark.circle.fill")
                    .font(.subheadline)
            }
            .buttonStyle(.bordered)
        }
    }

    private var summaryView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Summary")
                        .font(.headline)
                    Spacer()
                    Button {
                        UIPasteboard.general.string = summary
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                            .font(.caption)
                    }
                }
                Text(summary)
                    .font(.body)
            }
            .padding()
        }
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .frame(maxHeight: 400)
    }
    
    private var summaryPreview: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "doc.text.fill")
                    .foregroundStyle(.blue)
                Text("Summary")
                    .font(.headline)
                Spacer()
                Button {
                    showSummaryDetail = true
                } label: {
                    Label("View Full", systemImage: "arrow.up.left.and.arrow.down.right")
                        .font(.caption)
                }
            }
            
            Text(summary)
                .font(.body)
                .lineLimit(6)
                .padding(.vertical, 8)
            
            HStack {
                Button {
                    showSummaryDetail = true
                } label: {
                    HStack {
                        Image(systemName: "arrow.up.right.square")
                        Text("Tap to view full summary and export")
                    }
                    .font(.subheadline)
                    .foregroundStyle(.blue)
                }
                Spacer()
            }
        }
        .padding()
        .background(
            LinearGradient(
                colors: [Color.blue.opacity(0.1), Color.blue.opacity(0.05)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.blue.opacity(0.3), lineWidth: 2)
        )
        .shadow(color: .blue.opacity(0.2), radius: 8, x: 0, y: 4)
        .onTapGesture {
            showSummaryDetail = true
        }
    }
    
    private var logsView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Logs")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        UIPasteboard.general.string = logs.joined(separator: "\n")
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.caption)
                    }
                    Button {
                        logs.removeAll()
                    } label: {
                        Image(systemName: "trash")
                            .font(.caption)
                    }
                }
                ForEach(logs, id: \.self) { log in
                    Text(log)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(8)
        }
        .background(Color(.tertiarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .frame(maxHeight: 150)
    }
    
    private func addLog(_ message: String) {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        logs.append("[\(timestamp)] \(message)")
        print(message)
    }

    private func savePendingTranscription(jobName: String, sourceFileName: String) {
        UserDefaults.standard.set(jobName, forKey: PendingTranscriptionStorage.jobNameKey)
        UserDefaults.standard.set(sourceFileName, forKey: PendingTranscriptionStorage.sourceFileNameKey)
    }

    private func clearPendingTranscription() {
        UserDefaults.standard.removeObject(forKey: PendingTranscriptionStorage.jobNameKey)
        UserDefaults.standard.removeObject(forKey: PendingTranscriptionStorage.sourceFileNameKey)
    }

    // MARK: - Actions

    private func loadTranscript(_ transcriptText: String) {
        addLog("Loaded transcript from AWS: \(transcriptText.count) characters")
        transcript = transcriptText
        summary = ""
        status = .idle
        
        // Automatically start summarizing
        Task {
            await summarizeTranscript()
        }
    }
    
    private func summarizeTranscript() async {
        guard !transcript.isEmpty else { return }
        
        status = .summarizing
        addLog("Starting Bedrock summarization...")
        addLog("Transcript preview: \(transcript.prefix(100))...")
        do {
            summary = try await bedrock.summarize(transcript: transcript)
            addLog("Summary generated successfully")
            status = .done
        } catch {
            addLog("ERROR: \(error.localizedDescription)")
            showError(message: error.localizedDescription)
        }
    }

    private func handleRecordTap() {
        if recorder.isRecording {
            recorder.stopRecording()
            addLog("Recording stopped")
            processingTask = Task { await processRecording() }
        } else {
            summary = ""
            transcript = ""
            logs.removeAll()
            recorder.requestPermission { granted in
                if granted {
                    recorder.startRecording()
                    status = .recording
                    addLog("Recording started")
                } else {
                    addLog("ERROR: Microphone permission denied")
                    showError(message: "Microphone permission denied. Please enable it in Settings.")
                }
            }
        }
    }

    private func processRecording() async {
        guard let fileURL = recorder.recordingURL else { return }

        addLog("Processing recording: \(fileURL.lastPathComponent)")
        
        do {
            status = .uploading
            addLog("Uploading to S3...")
            let s3URI = try await aws.uploadToS3(fileURL: fileURL)
            addLog("Upload complete: \(s3URI)")

            status = .transcribing
            transcriptionProgress = ""
            let jobName = "meeting-\(Int(Date().timeIntervalSince1970))"
            addLog("Starting transcription job: \(jobName)")
            try await aws.startTranscriptionJob(s3URI: s3URI, jobName: jobName)
            savePendingTranscription(jobName: jobName, sourceFileName: fileURL.lastPathComponent)
            addLog("Polling for transcription...")
            
            transcript = try await aws.pollTranscriptionJob(jobName: jobName) { progress in
                Task { @MainActor in
                    transcriptionProgress = progress
                }
            }
            clearPendingTranscription()
            
            transcriptionProgress = ""
            addLog("Transcription complete: \(transcript.count) characters")
            addLog("Transcript preview: \(transcript.prefix(100))...")

            status = .summarizing
            addLog("Starting Bedrock summarization...")
            summary = try await bedrock.summarize(transcript: transcript)
            addLog("Summary generated: \(summary.count) characters")
            addLog("Summary preview: \(summary.prefix(100))...")

            status = .done
            addLog("All processing complete!")
        } catch {
            if let awsError = error as? AWSError, awsError == .transcribeFailed || awsError == .timeout {
                clearPendingTranscription()
            }
            addLog("ERROR: \(error.localizedDescription)")
            showError(message: error.localizedDescription)
        }
    }

    private func cancelProcessing() {
        processingTask?.cancel()
        processingTask = nil
        if recorder.isRecording {
            recorder.stopRecording()
        }
        clearPendingTranscription()
        transcriptionProgress = ""
        status = .idle
        addLog("Processing cancelled by user")
    }

    private func showError(message: String) {
        errorMessage = message
        showError = true
    }
    
    private func processLocalAudio(_ fileURL: URL) async {
        let fileName = fileURL.lastPathComponent
        
        addLog("Selected file: \(fileName)")
        
        // Check if we have a cached transcript
        if let cachedTranscript = TranscriptCache.shared.loadTranscript(for: fileName) {
            addLog("Found cached transcript! Skipping S3 upload and transcription.")
            addLog("Loaded \(cachedTranscript.count) characters from cache")
            
            transcript = cachedTranscript
            status = .summarizing
            
            do {
                addLog("Starting Bedrock summarization...")
                summary = try await bedrock.summarize(transcript: transcript)
                addLog("Summary generated: \(summary.count) characters")
                addLog("Summary preview: \(summary.prefix(100))...")
                status = .done
                addLog("All processing complete! (Used cached transcript)")
            } catch {
                addLog("ERROR: \(error.localizedDescription)")
                showError(message: error.localizedDescription)
            }
            
            return
        }
        
        addLog("No cached transcript found. Will upload and transcribe.")
        addLog("Uploaded files so far: \(uploadedFiles.joined(separator: ", "))")
        
        // Check for duplicate upload (but allow re-transcription if needed)
        if uploadedFiles.contains(fileName) {
            addLog("WARNING: File '\(fileName)' was already uploaded to S3.")
            addLog("Will use existing S3 file for transcription.")
        }
        
        // Clear previous results and set status immediately
        summary = ""
        transcript = ""
        status = .processing
        
        addLog("Processing local audio: \(fileName)")
        
        do {
            // Only upload if not already uploaded
            var s3URI: String
            if uploadedFiles.contains(fileName) {
                s3URI = "s3://\(Config.s3Bucket)/\(fileName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? fileName)"
                addLog("Using existing S3 file: \(s3URI)")
            } else {
                status = .uploading
                addLog("Uploading to S3...")
                s3URI = try await aws.uploadToS3(fileURL: fileURL)
                addLog("Upload complete: \(s3URI)")
                addToUploadedFiles(fileName)
                addLog("Added '\(fileName)' to uploaded files list")
            }

            status = .transcribing
            transcriptionProgress = ""
            let jobName = "local-\(Int(Date().timeIntervalSince1970))"
            addLog("Starting transcription job: \(jobName)")
            try await aws.startTranscriptionJob(s3URI: s3URI, jobName: jobName)
            savePendingTranscription(jobName: jobName, sourceFileName: fileName)
            addLog("Polling for transcription...")
            
            transcript = try await aws.pollTranscriptionJob(jobName: jobName) { progress in
                Task { @MainActor in
                    transcriptionProgress = progress
                }
            }
            clearPendingTranscription()
            
            transcriptionProgress = ""
            addLog("Transcription complete: \(transcript.count) characters")
            addLog("Transcript preview: \(transcript.prefix(100))...")
            
            // Cache the transcript
            TranscriptCache.shared.saveTranscript(transcript, for: fileName)
            addLog("Cached transcript for future use")

            status = .summarizing
            addLog("Starting Bedrock summarization...")
            summary = try await bedrock.summarize(transcript: transcript)
            addLog("Summary generated: \(summary.count) characters")
            addLog("Summary preview: \(summary.prefix(100))...")

            status = .done
            addLog("All processing complete!")
        } catch {
            if let awsError = error as? AWSError, awsError == .transcribeFailed || awsError == .timeout {
                clearPendingTranscription()
            }
            addLog("ERROR: \(error.localizedDescription)")
            showError(message: error.localizedDescription)
        }
    }
}

// MARK: - Supporting Types

enum AppStatus: Int {
    case idle, recording, uploading, transcribing, summarizing, done, processing

    var label: String {
        switch self {
        case .idle:         return "Ready to record"
        case .recording:    return "Recording..."
        case .uploading:    return "Uploading..."
        case .transcribing: return "Transcribing..."
        case .summarizing:  return "Summarizing..."
        case .done:         return "Done"
        case .processing:   return "Processing..."
        }
    }

    var color: Color {
        switch self {
        case .idle:         return .secondary
        case .recording:    return .red
        case .uploading,
             .transcribing,
             .summarizing,
             .processing:  return .orange
        case .done:         return .green
        }
    }
}

struct StepRow: View {
    let label: String
    let active: Bool
    let done: Bool

    var body: some View {
        HStack(spacing: 10) {
            if done {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            } else if active {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "circle").foregroundStyle(.secondary)
            }
            Text(label)
                .foregroundStyle(active ? .primary : .secondary)
        }
    }
}

#Preview {
    ContentView()
}
