import Foundation

class BedrockService {
    private let region: String
    private let modelId: String
    private let accessKey: String
    private let secretKey: String

    init(
        region: String = "us-east-1",
        modelId: String = "us.anthropic.claude-sonnet-4-6",
        accessKey: String,
        secretKey: String
    ) {
        self.region = region
        self.modelId = modelId
        self.accessKey = accessKey
        self.secretKey = secretKey
    }

    func summarize(transcript: String) async throws -> String {
        let endpoint = URL(string: "https://bedrock-runtime.\(region).amazonaws.com/model/\(modelId)/invoke")!

        let prompt = """
        You are an expert meeting summarizer.

        Please summarize the following meeting transcript. Include:
        1. **Overview** - What the meeting was about (2-3 sentences)
        2. **Key Discussion Points** - Main topics discussed
        3. **Decisions Made** - Any decisions reached
        4. **Action Items** - Tasks assigned with owners if mentioned
        5. **Next Steps** - Follow-up items

        Transcript:
        \(transcript)
        """

        let requestBody: [String: Any] = [
            "anthropic_version": "bedrock-2023-05-31",
            "max_tokens": 2048,
            "messages": [
                ["role": "user", "content": prompt]
            ]
        ]

        let bodyData = try JSONSerialization.data(withJSONObject: requestBody)

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        print("Bedrock request URL: \(endpoint)")
        print("Bedrock request body size: \(bodyData.count) bytes")

        let authHeader = try AWSSigV4.sign(
            request: &request,
            body: bodyData,
            service: "bedrock",
            region: region,
            accessKey: accessKey,
            secretKey: secretKey
        )
        request.setValue(authHeader, forHTTPHeaderField: "Authorization")
        request.httpBody = bodyData

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            print("Bedrock failed: Invalid response")
            throw BedrockError.invocationFailed("Invalid response")
        }
        
        if httpResponse.statusCode != 200 {
            let errorBody = String(data: data, encoding: .utf8) ?? "unknown"
            print("Bedrock failed with status \(httpResponse.statusCode): \(errorBody)")
            throw BedrockError.invocationFailed(errorBody)
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let content = json?["content"] as? [[String: Any]]
        guard let text = content?.first?["text"] as? String else {
            print("Bedrock response parsing failed")
            throw BedrockError.invalidResponse
        }

        print("Bedrock summary generated successfully")
        return text
    }
    
    func chat(transcript: String, question: String) async throws -> String {
        let endpoint = URL(string: "https://bedrock-runtime.\(region).amazonaws.com/model/\(modelId)/invoke")!

        let prompt = """
        You are Claude (\(modelId)) running on AWS Bedrock. You're a helpful AI assistant.
        
        The user has a meeting transcript. Here it is:
        
        \(transcript)
        
        User's question: \(question)
        
        Answer naturally. If they ask about the meeting/transcript, use it. If they ask about you or anything else, just answer normally.
        """

        let requestBody: [String: Any] = [
            "anthropic_version": "bedrock-2023-05-31",
            "max_tokens": 1024,
            "messages": [
                ["role": "user", "content": prompt]
            ]
        ]

        let bodyData = try JSONSerialization.data(withJSONObject: requestBody)

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let authHeader = try AWSSigV4.sign(
            request: &request,
            body: bodyData,
            service: "bedrock",
            region: region,
            accessKey: accessKey,
            secretKey: secretKey
        )
        request.setValue(authHeader, forHTTPHeaderField: "Authorization")
        request.httpBody = bodyData

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw BedrockError.invocationFailed("Invalid response")
        }
        
        if httpResponse.statusCode != 200 {
            let errorBody = String(data: data, encoding: .utf8) ?? "unknown"
            throw BedrockError.invocationFailed(errorBody)
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let content = json?["content"] as? [[String: Any]]
        guard let text = content?.first?["text"] as? String else {
            throw BedrockError.invalidResponse
        }

        return text
    }
}

enum BedrockError: Error, LocalizedError {
    case invocationFailed(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .invocationFailed(let msg): return "Bedrock invocation failed: \(msg)"
        case .invalidResponse: return "Unexpected response format from Bedrock"
        }
    }
}
