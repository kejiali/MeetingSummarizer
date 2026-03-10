import Foundation

class TranscriptCache {
    static let shared = TranscriptCache()
    
    private let fileManager = FileManager.default
    private var cacheDirectory: URL {
        let paths = fileManager.urls(for: .documentDirectory, in: .userDomainMask)
        let cacheDir = paths[0].appendingPathComponent("TranscriptCache")
        
        // Create directory if it doesn't exist
        if !fileManager.fileExists(atPath: cacheDir.path) {
            try? fileManager.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        }
        
        return cacheDir
    }
    
    // Generate cache key from filename
    private func cacheKey(for fileName: String) -> String {
        return fileName.replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "/", with: "_")
    }
    
    // Save transcript to local storage
    func saveTranscript(_ transcript: String, for fileName: String) {
        let key = cacheKey(for: fileName)
        let fileURL = cacheDirectory.appendingPathComponent("\(key).txt")
        
        do {
            try transcript.write(to: fileURL, atomically: true, encoding: .utf8)
            print("Cached transcript for '\(fileName)' at \(fileURL.path)")
        } catch {
            print("Failed to cache transcript: \(error)")
        }
    }
    
    // Load transcript from local storage
    func loadTranscript(for fileName: String) -> String? {
        let key = cacheKey(for: fileName)
        let fileURL = cacheDirectory.appendingPathComponent("\(key).txt")
        
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return nil
        }
        
        do {
            let transcript = try String(contentsOf: fileURL, encoding: .utf8)
            print("Loaded cached transcript for '\(fileName)' (\(transcript.count) characters)")
            return transcript
        } catch {
            print("Failed to load cached transcript: \(error)")
            return nil
        }
    }
    
    // Check if transcript exists in cache
    func hasTranscript(for fileName: String) -> Bool {
        let key = cacheKey(for: fileName)
        let fileURL = cacheDirectory.appendingPathComponent("\(key).txt")
        return fileManager.fileExists(atPath: fileURL.path)
    }
    
    // Delete cached transcript
    func deleteTranscript(for fileName: String) {
        let key = cacheKey(for: fileName)
        let fileURL = cacheDirectory.appendingPathComponent("\(key).txt")
        
        try? fileManager.removeItem(at: fileURL)
        print("Deleted cached transcript for '\(fileName)'")
    }
    
    // List all cached transcripts
    func listCachedFiles() -> [String] {
        guard let files = try? fileManager.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil) else {
            return []
        }
        
        return files.map { $0.lastPathComponent.replacingOccurrences(of: ".txt", with: "") }
    }
    
    // Clear all cached transcripts
    func clearCache() {
        guard let files = try? fileManager.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil) else {
            return
        }
        
        for file in files {
            try? fileManager.removeItem(at: file)
        }
        
        print("Cleared all cached transcripts")
    }
}
