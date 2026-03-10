import SwiftUI
import CoreData
import Combine

@MainActor
final class AppResumeState: ObservableObject {
    private enum PendingTranscriptionStorage {
        static let jobNameKey = "pendingTranscriptionJobName"
        static let sourceFileNameKey = "pendingTranscriptionSourceFileName"
    }

    @Published var statusMessage: String = ""
    @Published var summary: String = ""
    @Published var transcript: String = ""
    @Published var errorMessage: String?

    private var hasAttemptedResume = false

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

    func resumePendingTranscriptionIfNeeded() {
        guard !hasAttemptedResume else { return }
        hasAttemptedResume = true

        guard let jobName = UserDefaults.standard.string(forKey: PendingTranscriptionStorage.jobNameKey), !jobName.isEmpty else {
            return
        }

        let sourceFileName = UserDefaults.standard.string(forKey: PendingTranscriptionStorage.sourceFileNameKey) ?? "recording"

        statusMessage = "Resuming transcription..."

        Task {
            do {
                let resumedTranscript = try await aws.pollTranscriptionJob(jobName: jobName)
                transcript = resumedTranscript
                summary = try await bedrock.summarize(transcript: resumedTranscript)
                if sourceFileName != "recording" {
                    TranscriptCache.shared.saveTranscript(resumedTranscript, for: sourceFileName)
                }
                clearPendingTranscription()
                statusMessage = ""
            } catch {
                if let awsError = error as? AWSError, (awsError == .transcribeFailed || awsError == .timeout) {
                    clearPendingTranscription()
                }
                statusMessage = ""
                errorMessage = error.localizedDescription
            }
        }
    }

    func consumeErrorMessage() {
        errorMessage = nil
    }

    private func clearPendingTranscription() {
        UserDefaults.standard.removeObject(forKey: PendingTranscriptionStorage.jobNameKey)
        UserDefaults.standard.removeObject(forKey: PendingTranscriptionStorage.sourceFileNameKey)
    }
}

@main
struct MeetingSummarizerApp: App {
    let persistenceController = PersistenceController.shared
    @StateObject private var resumeState = AppResumeState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(resumeState)
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
                .onAppear {
                    resumeState.resumePendingTranscriptionIfNeeded()
                }
        }
    }
}
