import SwiftUI

struct TranscribeJobsView: View {
    @State private var jobs: [TranscriptionJob] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showDeleteAlert = false
    @State private var jobToDelete: TranscriptionJob?
    @Binding var selectedTranscript: String?
    @Environment(\.dismiss) var dismiss
    
    private let aws = AWSService(
        region: Config.awsRegion,
        bucketName: Config.s3Bucket,
        accessKey: Config.awsAccessKey,
        secretKey: Config.awsSecretKey
    )
    
    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Loading transcription jobs...")
                } else if let error = errorMessage {
                    VStack(spacing: 16) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle)
                            .foregroundStyle(.orange)
                        Text(error)
                            .multilineTextAlignment(.center)
                        Button("Retry") {
                            Task { await loadJobs() }
                        }
                    }
                    .padding()
                } else if jobs.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "tray")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("No transcription jobs found")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    List {
                        ForEach(jobs) { job in
                            HStack {
                                Button {
                                    Task {
                                        await selectJob(job)
                                    }
                                } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(job.name)
                                            .font(.headline)
                                        Text(job.date, style: .date)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        HStack {
                                            statusBadge(for: job.status)
                                            if let language = job.languageCode {
                                                Text(language)
                                                    .font(.caption2)
                                                    .padding(.horizontal, 6)
                                                    .padding(.vertical, 2)
                                                    .background(Color.blue.opacity(0.1))
                                                    .foregroundStyle(.blue)
                                                    .clipShape(Capsule())
                                            }
                                        }
                                    }
                                    .padding(.vertical, 4)
                                }
                                .disabled(job.status != "COMPLETED")
                                
                                Spacer()
                                
                                Button {
                                    jobToDelete = job
                                    showDeleteAlert = true
                                } label: {
                                    Image(systemName: "trash")
                                        .foregroundStyle(.red)
                                }
                                .buttonStyle(.borderless)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    jobToDelete = job
                                    showDeleteAlert = true
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("AWS Transcribe Jobs")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Close") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        Task { await loadJobs() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(isLoading)
                }
            }
            .task {
                await loadJobs()
            }
            .alert("Delete Transcription Job", isPresented: $showDeleteAlert) {
                Button("Cancel", role: .cancel) { }
                Button("Delete", role: .destructive) {
                    if let job = jobToDelete {
                        Task { await deleteJob(job) }
                    }
                }
            } message: {
                if let job = jobToDelete {
                    Text("This will delete the transcription job '\(job.name)' and its audio file from S3. This action cannot be undone.")
                }
            }
        }
    }
    
    private func statusBadge(for status: String) -> some View {
        let color: Color = {
            switch status {
            case "COMPLETED": return .green
            case "IN_PROGRESS": return .orange
            case "FAILED": return .red
            default: return .gray
            }
        }()
        
        return Text(status)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.1))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }
    
    private func loadJobs() async {
        isLoading = true
        errorMessage = nil
        
        do {
            jobs = try await aws.listTranscriptionJobs()
            print("Loaded \(jobs.count) transcription jobs")
        } catch {
            errorMessage = error.localizedDescription
            print("Failed to load jobs: \(error)")
        }
        
        isLoading = false
    }
    
    private func selectJob(_ job: TranscriptionJob) async {
        guard job.status == "COMPLETED" else {
            return
        }
        
        isLoading = true
        
        do {
            // First get the transcript URI
            let transcriptURI = try await aws.getTranscriptURI(jobName: job.name)
            // Then fetch the actual transcript text
            let transcript = try await aws.fetchTranscriptFromURI(transcriptURI)
            selectedTranscript = transcript
            dismiss()
        } catch {
            errorMessage = "Failed to fetch transcript: \(error.localizedDescription)"
            isLoading = false
        }
    }
    
    private func deleteJob(_ job: TranscriptionJob) async {
        isLoading = true
        errorMessage = nil
        
        do {
            // Extract S3 key from job name (assuming format: meeting-timestamp.m4a)
            let s3Key = "\(job.name).m4a"
            
            // Delete from S3 first
            print("Deleting S3 object: \(s3Key)")
            try await aws.deleteFromS3(key: s3Key)
            
            // Then delete transcription job
            print("Deleting transcription job: \(job.name)")
            try await aws.deleteTranscriptionJob(jobName: job.name)
            
            // Remove from local list
            jobs.removeAll { $0.id == job.id }
            print("Successfully deleted job and audio file")
            
        } catch {
            errorMessage = "Failed to delete: \(error.localizedDescription)"
            print("Delete failed: \(error)")
        }
        
        isLoading = false
        jobToDelete = nil
    }
}

struct TranscriptionJob: Identifiable {
    let id = UUID()
    let name: String
    let status: String
    let date: Date
    let languageCode: String?
    let transcriptURI: String?
}
