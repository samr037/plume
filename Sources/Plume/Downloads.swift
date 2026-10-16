import Foundation

/// Modèles téléchargés au premier lancement (rien n'est livré dans le DMG).
enum ModelFiles {
    /// LLM de mise au propre : Qwen3.5 4B (Apache-2.0), quantifié Q5_K_M.
    static let llmFileName = "Qwen3.5-4B-Q5_K_M.gguf"
    static let llmURL = URL(string: "https://huggingface.co/unsloth/Qwen3.5-4B-GGUF/resolve/main/Qwen3.5-4B-Q5_K_M.gguf")!

    static var defaultLLMPath: String {
        AppSettings.supportDirectory.appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent(llmFileName).path
    }
}

/// Téléchargement d'un gros fichier avec progression et reprise : les octets arrivent dans `<dest>.part`,
/// une coupure reprend là où elle s'est arrêtée (en-tête Range), et le fichier n'est renommé qu'une fois complet.
final class FileDownloader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    struct Progress: Sendable {
        var received: Int64
        var total: Int64?
        var fraction: Double? { total.map { $0 > 0 ? Double(received) / Double($0) : 0 } }
    }

    private let url: URL
    private let dest: URL
    private let part: URL
    private let onProgress: @Sendable (Progress) -> Void
    private var handle: FileHandle?
    private var received: Int64 = 0
    private var total: Int64?
    private var lastReport = Date.distantPast
    private var continuation: CheckedContinuation<Void, Error>?
    private var session: URLSession?

    init(url: URL, to dest: URL, onProgress: @escaping @Sendable (Progress) -> Void) {
        self.url = url
        self.dest = dest
        self.part = dest.appendingPathExtension("part")
        self.onProgress = onProgress
    }

    func run() async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: part.path) { fm.createFile(atPath: part.path, contents: nil) }
        received = (try? fm.attributesOfItem(atPath: part.path)[.size] as? Int64) ?? 0
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        if received > 0 { request.setValue("bytes=\(received)-", forHTTPHeaderField: "Range") }
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        self.session = session
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                continuation = c
                session.dataTask(with: request).resume()
            }
        } onCancel: {
            session.invalidateAndCancel()
        }
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try fm.moveItem(at: part, to: dest)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else { completionHandler(.cancel); return }
        do {
            let h = try FileHandle(forWritingTo: part)
            switch http.statusCode {
            case 206:
                try h.seekToEnd()
            case 200:
                // Le serveur ignore la reprise : on repart de zéro.
                try h.truncate(atOffset: 0)
                received = 0
            default:
                try? h.close()
                finish(URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"]))
                completionHandler(.cancel)
                return
            }
            handle = h
            if http.expectedContentLength > 0 { total = received + http.expectedContentLength }
            completionHandler(.allow)
        } catch {
            finish(error)
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            try handle?.write(contentsOf: data)
        } catch {
            finish(error)
            dataTask.cancel()
            return
        }
        received += Int64(data.count)
        if Date().timeIntervalSince(lastReport) > 0.25 {
            lastReport = Date()
            onProgress(Progress(received: received, total: total))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        try? handle?.close()
        handle = nil
        if let error { finish(error); return }
        if let total, received != total {
            finish(URLError(.networkConnectionLost, userInfo: [NSLocalizedDescriptionKey: "Téléchargement incomplet"]))
            return
        }
        onProgress(Progress(received: received, total: total ?? received))
        finish(nil)
    }

    private func finish(_ error: Error?) {
        guard let c = continuation else { return }
        continuation = nil
        session?.finishTasksAndInvalidate()
        if let error { c.resume(throwing: error) } else { c.resume() }
    }
}

enum ByteFormat {
    static func string(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
