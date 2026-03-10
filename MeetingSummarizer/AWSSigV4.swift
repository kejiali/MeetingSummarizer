import Foundation
import CryptoKit
import CommonCrypto

enum AWSSigV4 {
    static func sign(
        request: inout URLRequest,
        body: Data,
        service: String,
        region: String,
        accessKey: String,
        secretKey: String
    ) throws -> String {
        let now = Date()
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = TimeZone(identifier: "UTC")

        dateFormatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let amzDate = dateFormatter.string(from: now)

        dateFormatter.dateFormat = "yyyyMMdd"
        let dateStamp = dateFormatter.string(from: now)

        let url = request.url!
        let host = url.host!
        let method = request.httpMethod ?? "GET"

        // Set required headers
        request.setValue(amzDate, forHTTPHeaderField: "x-amz-date")
        request.setValue(host, forHTTPHeaderField: "Host")

        // Collect headers to sign (lowercase, sorted)
        var headersToSign: [(String, String)] = []
        
        // Bedrock uses minimal signing (only host and x-amz-date)
        if service == "bedrock" {
            headersToSign.append(("host", host))
            headersToSign.append(("x-amz-date", amzDate))
        } else {
            // Other services include more headers
            let bodyHash = SHA256.hash(data: body).hexString
            request.setValue(bodyHash, forHTTPHeaderField: "x-amz-content-sha256")
            
            if let contentType = request.value(forHTTPHeaderField: "Content-Type") {
                headersToSign.append(("content-type", contentType))
            }
            headersToSign.append(("host", host))
            headersToSign.append(("x-amz-content-sha256", bodyHash))
            headersToSign.append(("x-amz-date", amzDate))
            
            // Add X-Amz-Target if present (for Transcribe)
            if let target = request.value(forHTTPHeaderField: "X-Amz-Target") {
                headersToSign.append(("x-amz-target", target))
            }
        }
        
        headersToSign.sort { $0.0 < $1.0 }
        
        let signedHeaders = headersToSign.map { $0.0 }.joined(separator: ";")
        let canonicalHeaders = headersToSign.map { "\($0.0):\($0.1)" }.joined(separator: "\n") + "\n"

        // Get canonical URI - needs proper URL encoding
        var canonicalURI = url.path.isEmpty ? "/" : url.path
        
        // For S3, we need to ensure the path is properly URL-encoded
        if service == "s3" {
            // The path should already be encoded in the URL, but we need to ensure it's in canonical form
            canonicalURI = canonicalURI.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? canonicalURI
            // AWS requires spaces as %20, not +
            canonicalURI = canonicalURI.replacingOccurrences(of: "+", with: "%20")
        } else if service == "bedrock" {
            // AWS SigV4 requires colons to be percent-encoded in the path for Bedrock
            canonicalURI = canonicalURI.replacingOccurrences(of: ":", with: "%3A")
        }
        
        let canonicalQueryString = url.query ?? ""
        
        let bodyHash = SHA256.hash(data: body).hexString

        let canonicalRequest = [method, canonicalURI, canonicalQueryString, canonicalHeaders, signedHeaders, bodyHash].joined(separator: "\n")
        
        // Debug logging
        print("=== AWS SigV4 Debug ===")
        print("Service: \(service)")
        print("Method: \(method)")
        print("Canonical URI: \(canonicalURI)")
        print("Canonical Query: \(canonicalQueryString)")
        print("Canonical Headers:\n\(canonicalHeaders)")
        print("Signed Headers: \(signedHeaders)")
        print("Body Hash: \(bodyHash)")
        print("Body size: \(body.count)")
        print("Canonical Request:\n\(canonicalRequest)")
        print("======================")

        // String to sign
        let credentialScope = "\(dateStamp)/\(region)/\(service)/aws4_request"
        let canonicalRequestHash = SHA256.hash(data: Data(canonicalRequest.utf8)).hexString
        let stringToSign = "AWS4-HMAC-SHA256\n\(amzDate)\n\(credentialScope)\n\(canonicalRequestHash)"

        // Signing key
        let signingKey = try deriveSigningKey(secretKey: secretKey, dateStamp: dateStamp, region: region, service: service)
        let signature = HMAC<SHA256>.authenticationCode(for: Data(stringToSign.utf8), using: signingKey).hexString

        return "AWS4-HMAC-SHA256 Credential=\(accessKey)/\(credentialScope), SignedHeaders=\(signedHeaders), Signature=\(signature)"
    }

    private static func deriveSigningKey(secretKey: String, dateStamp: String, region: String, service: String) throws -> SymmetricKey {
        let kSecret = Data("AWS4\(secretKey)".utf8)
        let kDate = HMAC<SHA256>.authenticationCode(for: Data(dateStamp.utf8), using: SymmetricKey(data: kSecret))
        let kRegion = HMAC<SHA256>.authenticationCode(for: Data(region.utf8), using: SymmetricKey(data: Data(kDate)))
        let kService = HMAC<SHA256>.authenticationCode(for: Data(service.utf8), using: SymmetricKey(data: Data(kRegion)))
        let kSigning = HMAC<SHA256>.authenticationCode(for: Data("aws4_request".utf8), using: SymmetricKey(data: Data(kService)))
        return SymmetricKey(data: Data(kSigning))
    }
}

extension Digest {
    var hexString: String {
        self.map { String(format: "%02x", $0) }.joined()
    }
}

extension HMAC<SHA256>.MAC {
    var hexString: String {
        self.map { String(format: "%02x", $0) }.joined()
    }
}
