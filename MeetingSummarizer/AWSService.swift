import Foundation

class AWSService {
    private let region: String
    private let bucketName: String
    private let accessKey: String
    private let secretKey: String

    init(region: String = "us-east-1", bucketName: String, accessKey: String, secretKey: String) {
        self.region = region
        self.bucketName = bucketName
        self.accessKey = accessKey
        self.secretKey = secretKey
    }

    // MARK: - S3 Upload

    func uploadToS3(fileURL: URL, retries: Int = 3) async throws -> String {
        let key = fileURL.lastPathComponent
        
        // URL-encode the key for the S3 URL
        guard let encodedKey = key.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            print("ERROR: Failed to encode filename")
            throw AWSError.uploadFailed
        }
        
        guard let s3URL = URL(string: "https://\(bucketName).s3.\(region).amazonaws.com/\(encodedKey)") else {
            print("ERROR: Failed to create S3 URL")
            throw AWSError.uploadFailed
        }

        print("Attempting to upload file: \(fileURL.path)")
        print("S3 Key: \(key)")
        print("S3 URL: \(s3URL)")
        print("File exists: \(FileManager.default.fileExists(atPath: fileURL.path))")
        
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            print("ERROR: File does not exist at path: \(fileURL.path)")
            throw AWSError.uploadFailed
        }
        
        let fileData: Data
        do {
            fileData = try Data(contentsOf: fileURL)
            print("File size: \(fileData.count) bytes")
        } catch {
            print("ERROR: Failed to read file data: \(error.localizedDescription)")
            throw error
        }
        
        let contentType = "audio/mp4"
        
        var lastError: Error?
        
        for attempt in 1...retries {
            do {
                print("Upload attempt \(attempt)/\(retries)")
                let date = ISO8601DateFormatter().string(from: Date())
                
                var request = URLRequest(url: s3URL)
                request.httpMethod = "PUT"
                request.setValue(contentType, forHTTPHeaderField: "Content-Type")
                request.setValue(date, forHTTPHeaderField: "x-amz-date")
                request.setValue("aws4_request", forHTTPHeaderField: "x-amz-content-sha256")

                let authHeader = try AWSSigV4.sign(
                    request: &request,
                    body: fileData,
                    service: "s3",
                    region: region,
                    accessKey: accessKey,
                    secretKey: secretKey
                )
                request.setValue(authHeader, forHTTPHeaderField: "Authorization")
                request.httpBody = fileData

                let (data, response) = try await URLSession.shared.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse else {
                    print("S3 upload failed: Invalid response")
                    throw AWSError.uploadFailed
                }
                
                if httpResponse.statusCode != 200 {
                    let errorBody = String(data: data, encoding: .utf8) ?? "No error body"
                    print("S3 upload failed with status \(httpResponse.statusCode): \(errorBody)")
                    throw AWSError.uploadFailed
                }
                
                print("S3 upload successful: s3://\(bucketName)/\(key)")
                return "s3://\(bucketName)/\(key)"
                
            } catch let error as URLError where error.code == .notConnectedToInternet || error.code == .networkConnectionLost {
                lastError = error
                print("Network error on attempt \(attempt)/\(retries): \(error.localizedDescription)")
                if attempt < retries {
                    print("Retrying in 2 seconds...")
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                }
            } catch {
                // Non-network errors shouldn't be retried
                print("Upload error (non-network): \(error.localizedDescription)")
                throw error
            }
        }
        
        throw lastError ?? AWSError.uploadFailed
    }

    // MARK: - Amazon Transcribe

    func startTranscriptionJob(s3URI: String, jobName: String) async throws {
        let endpoint = URL(string: "https://transcribe.\(region).amazonaws.com/")!
        let body: [String: Any] = [
            "TranscriptionJobName": jobName,
            "LanguageCode": "en-US",
            "MediaFormat": "mp4",
            "Media": ["MediaFileUri": s3URI]
        ]

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-amz-json-1.1", forHTTPHeaderField: "Content-Type")
        request.setValue("Transcribe.StartTranscriptionJob", forHTTPHeaderField: "X-Amz-Target")

        let bodyData = try JSONSerialization.data(withJSONObject: body)
        let authHeader = try AWSSigV4.sign(
            request: &request,
            body: bodyData,
            service: "transcribe",
            region: region,
            accessKey: accessKey,
            secretKey: secretKey
        )
        request.setValue(authHeader, forHTTPHeaderField: "Authorization")
        request.httpBody = bodyData

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            print("Transcribe start failed: Invalid response")
            throw AWSError.transcribeFailed
        }
        
        if httpResponse.statusCode != 200 {
            let errorBody = String(data: data, encoding: .utf8) ?? "No error body"
            print("Transcribe start failed with status \(httpResponse.statusCode): \(errorBody)")
            throw AWSError.transcribeFailed
        }
        
        print("Transcription job started: \(jobName)")
    }

    func pollTranscriptionJob(jobName: String, onProgress: ((String) -> Void)? = nil) async throws -> String {
        let endpoint = URL(string: "https://transcribe.\(region).amazonaws.com/")!

        for attempt in 0..<60 {
            try await Task.sleep(nanoseconds: 10_000_000_000) // 10 seconds

            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.setValue("application/x-amz-json-1.1", forHTTPHeaderField: "Content-Type")
            request.setValue("Transcribe.GetTranscriptionJob", forHTTPHeaderField: "X-Amz-Target")
            
            let body = ["TranscriptionJobName": jobName]
            let bodyData = try JSONSerialization.data(withJSONObject: body)
            
            let authHeader = try AWSSigV4.sign(
                request: &request,
                body: bodyData,
                service: "transcribe",
                region: region,
                accessKey: accessKey,
                secretKey: secretKey
            )
            request.setValue(authHeader, forHTTPHeaderField: "Authorization")
            request.httpBody = bodyData

            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                let errorBody = String(data: data, encoding: .utf8) ?? "No error body"
                print("Poll transcription failed: \(errorBody)")
                throw AWSError.transcribeFailed
            }
            
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let job = json?["TranscriptionJob"] as? [String: Any]
            let status = job?["TranscriptionJobStatus"] as? String

            let progressMessage = "Checking status (attempt \(attempt + 1)/60): \(status ?? "unknown")"
            print("Transcription status (attempt \(attempt + 1)): \(status ?? "unknown")")
            onProgress?(progressMessage)

            if status == "COMPLETED" {
                let result = job?["Transcript"] as? [String: Any]
                guard let transcriptURI = result?["TranscriptFileUri"] as? String,
                      let url = URL(string: transcriptURI) else {
                    print("Failed to get transcript URI")
                    throw AWSError.transcribeFailed
                }
                return try await fetchTranscriptText(from: url)
            } else if status == "FAILED" {
                let failureReason = job?["FailureReason"] as? String ?? "Unknown reason"
                print("Transcription failed: \(failureReason)")
                throw AWSError.transcribeFailed
            }
        }
        throw AWSError.timeout
    }

    private func fetchTranscriptText(from url: URL) async throws -> String {
        let (data, _) = try await URLSession.shared.data(from: url)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let results = json?["results"] as? [String: Any]
        let transcripts = results?["transcripts"] as? [[String: Any]]
        return transcripts?.first?["transcript"] as? String ?? ""
    }
    
    // MARK: - List Transcription Jobs
    
    func listTranscriptionJobs(maxResults: Int = 50) async throws -> [TranscriptionJob] {
        let endpoint = URL(string: "https://transcribe.\(region).amazonaws.com/")!
        let body: [String: Any] = [
            "MaxResults": maxResults,
            "Status": "COMPLETED"
        ]
        
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-amz-json-1.1", forHTTPHeaderField: "Content-Type")
        request.setValue("Transcribe.ListTranscriptionJobs", forHTTPHeaderField: "X-Amz-Target")
        
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        let authHeader = try AWSSigV4.sign(
            request: &request,
            body: bodyData,
            service: "transcribe",
            region: region,
            accessKey: accessKey,
            secretKey: secretKey
        )
        request.setValue(authHeader, forHTTPHeaderField: "Authorization")
        request.httpBody = bodyData
        
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "No error body"
            print("List jobs failed: \(errorBody)")
            throw AWSError.transcribeFailed
        }
        
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let summaries = json?["TranscriptionJobSummaries"] as? [[String: Any]] ?? []
        
        return summaries.compactMap { summary in
            guard let name = summary["TranscriptionJobName"] as? String,
                  let status = summary["TranscriptionJobStatus"] as? String else {
                return nil
            }
            
            let dateString = summary["CreationTime"] as? Double
            let date = dateString.map { Date(timeIntervalSince1970: $0) } ?? Date()
            let languageCode = summary["LanguageCode"] as? String
            
            return TranscriptionJob(
                name: name,
                status: status,
                date: date,
                languageCode: languageCode,
                transcriptURI: nil
            )
        }
    }
    
    func fetchTranscriptFromURI(_ uri: String) async throws -> String {
        guard let url = URL(string: uri) else {
            throw AWSError.transcribeFailed
        }
        return try await fetchTranscriptText(from: url)
    }
    
    func getTranscriptURI(jobName: String) async throws -> String {
        let endpoint = URL(string: "https://transcribe.\(region).amazonaws.com/")!
        
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-amz-json-1.1", forHTTPHeaderField: "Content-Type")
        request.setValue("Transcribe.GetTranscriptionJob", forHTTPHeaderField: "X-Amz-Target")
        
        let body = ["TranscriptionJobName": jobName]
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        
        let authHeader = try AWSSigV4.sign(
            request: &request,
            body: bodyData,
            service: "transcribe",
            region: region,
            accessKey: accessKey,
            secretKey: secretKey
        )
        request.setValue(authHeader, forHTTPHeaderField: "Authorization")
        request.httpBody = bodyData
        
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw AWSError.transcribeFailed
        }
        
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let job = json?["TranscriptionJob"] as? [String: Any]
        let result = job?["Transcript"] as? [String: Any]
        guard let transcriptURI = result?["TranscriptFileUri"] as? String else {
            throw AWSError.transcribeFailed
        }
        
        return transcriptURI
    }
    
    // MARK: - Delete Operations
    
    func deleteTranscriptionJob(jobName: String) async throws {
        let endpoint = URL(string: "https://transcribe.\(region).amazonaws.com/")!
        
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-amz-json-1.1", forHTTPHeaderField: "Content-Type")
        request.setValue("Transcribe.DeleteTranscriptionJob", forHTTPHeaderField: "X-Amz-Target")
        
        let body = ["TranscriptionJobName": jobName]
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        
        let authHeader = try AWSSigV4.sign(
            request: &request,
            body: bodyData,
            service: "transcribe",
            region: region,
            accessKey: accessKey,
            secretKey: secretKey
        )
        request.setValue(authHeader, forHTTPHeaderField: "Authorization")
        request.httpBody = bodyData
        
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "No error body"
            print("Delete transcription job failed: \(errorBody)")
            throw AWSError.transcribeFailed
        }
        
        print("Transcription job deleted: \(jobName)")
    }
    
    func deleteFromS3(key: String) async throws {
        let s3URL = URL(string: "https://\(bucketName).s3.\(region).amazonaws.com/\(key)")!
        
        var request = URLRequest(url: s3URL)
        request.httpMethod = "DELETE"
        
        let authHeader = try AWSSigV4.sign(
            request: &request,
            body: Data(),
            service: "s3",
            region: region,
            accessKey: accessKey,
            secretKey: secretKey
        )
        request.setValue(authHeader, forHTTPHeaderField: "Authorization")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            print("S3 delete failed: Invalid response")
            throw AWSError.uploadFailed
        }
        
        guard httpResponse.statusCode == 204 || httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "No error body"
            print("S3 delete failed with status \(httpResponse.statusCode): \(errorBody)")
            throw AWSError.uploadFailed
        }
        
        print("S3 object deleted: \(key)")
    }
}

enum AWSError: Error, LocalizedError {
    case uploadFailed
    case transcribeFailed
    case timeout

    var errorDescription: String? {
        switch self {
        case .uploadFailed: return "Failed to upload audio to S3"
        case .transcribeFailed: return "Transcription job failed"
        case .timeout: return "Transcription timed out after 10 minutes"
        }
    }
}
