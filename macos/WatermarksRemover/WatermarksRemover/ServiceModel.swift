import AppKit
import Foundation

struct EvidenceClass: Decodable {
    let present: Bool
    let strength: String
    let summary: String

    enum CodingKeys: String, CodingKey {
        case present, strength
        case summary = "description"
    }
}

struct SuspiciousReport: Decodable {
    let verdict: Bool
    let summary: String
    let classes: [String: EvidenceClass]

    enum CodingKeys: String, CodingKey {
        case verdict, classes
        case summary = "description"
    }
}

struct InspectResult {
    let kind: String
    let suspicious: SuspiciousReport?
    let suspiciousTotal: Int?
    let detail: String
}

struct CleanResult {
    let kind: String
    let data: Data
    let summary: String
    let layerAOnly: Bool
}

@MainActor
final class ServiceModel: ObservableObject {
    @Published var connected = false
    @Published var version: String?
    @Published var status = "Looking for the local service."
    @Published var repoPath: String?
    @Published var busy = false
    @Published var lastError: String?

    private var child: Process?
    private let port = 8765
    private let repoDefaultsKey = "watermarksRepoPath"

    private var baseURL: URL {
        URL(string: "http://127.0.0.1:\(port)")!
    }

    func prepare() async {
        locateRepo()
        await refresh()
        if !connected {
            await startService()
        }
    }

    func refresh() async {
        if let health = try? await getHealth() {
            connected = health.ok
            version = health.version
            status = health.ok ? "Service \(health.version ?? "dev") on port \(port)." : "Service refused the health check."
            lastError = nil
        } else {
            connected = false
            version = nil
            status = "No service on port \(port)."
        }
    }

    func chooseRepo() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.prompt = "Use This Folder"
        panel.message = "Choose the watermarks-remover checkout."
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                self?.adoptRepo(url)
            }
        }
    }

    func startService() async {
        guard let repoPath else {
            lastError = "Choose the watermarks-remover folder so the app can start the service."
            return
        }
        if connected { return }
        let python = Self.pythonExecutable()
        let process = Process()
        process.currentDirectoryURL = URL(fileURLWithPath: repoPath)
        if python == "/usr/bin/env" {
            process.executableURL = URL(fileURLWithPath: python)
            process.arguments = ["python3", "service/scripts/server.py", "--host", "127.0.0.1", "--port", "\(port)"]
        } else {
            process.executableURL = URL(fileURLWithPath: python)
            process.arguments = ["service/scripts/server.py", "--host", "127.0.0.1", "--port", "\(port)"]
        }
        process.standardError = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            lastError = "Could not start Python: \(error.localizedDescription)"
            return
        }
        child = process
        for _ in 0..<20 {
            if Task.isCancelled { return }
            await refresh()
            if connected { return }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        lastError = "The service did not answer on port \(port)."
    }

    func stopServiceIfStarted() {
        child?.terminate()
        child = nil
    }

    func inspect(data: Data, name: String) async -> InspectResult? {
        await run {
            let (payload, http) = try await self.post(path: "inspect", body: Self.fileBody(data: data, name: name))
            try Self.throwIfNeeded(payload, status: http.statusCode)
            let object = try Self.jsonObject(payload)
            let suspicious = Self.decode(SuspiciousReport.self, from: object["suspicious"])
            let report = object["report"] as? [String: Any]
            let total = report?["suspicious_total"] as? Int
            let kind = object["kind"] as? String ?? "unknown"
            return InspectResult(
                kind: kind,
                suspicious: suspicious,
                suspiciousTotal: total,
                detail: Self.inspectDetail(report: report, suspicious: suspicious)
            )
        }
    }

    func clean(data: Data, name: String) async -> CleanResult? {
        await run {
            let (payload, http) = try await self.post(path: "clean", body: Self.fileBody(data: data, name: name))
            if http.statusCode >= 400 {
                let message = (try? Self.jsonObject(payload))?["error"] as? String ?? "Clean failed."
                if Self.isLayerBRefusal(message), let repo = self.repoPath, Self.looksLikeText(name: name, data: data) {
                    return try await self.layerAClean(repo: repo, text: String(decoding: data, as: UTF8.self))
                }
                throw ServiceFailure(message)
            }
            let object = try Self.jsonObject(payload)
            guard let cleanedB64 = object["cleaned"] as? String, let cleaned = Data(base64Encoded: cleanedB64) else {
                throw ServiceFailure("The service returned no cleaned file.")
            }
            let kind = object["kind"] as? String ?? "unknown"
            let report = object["report"] as? [String: Any]
            return CleanResult(
                kind: kind,
                data: cleaned,
                summary: Self.cleanSummary(report: report, bytes: cleaned.count),
                layerAOnly: false
            )
        }
    }

    private func layerAClean(repo: String, text: String) async throws -> CleanResult {
        let outcome = try await Task.detached {
            try ServiceModel.layerACleanSync(repo: repo, text: text)
        }.value
        let removed = Self.removedCount(fromStats: outcome.1)
        let summary = removed.map { "Removed \($0) invisible marks. Statistical rewrite is not configured." }
            ?? "Stripped invisible characters. Statistical rewrite is not configured."
        return CleanResult(kind: "text", data: outcome.0, summary: summary, layerAOnly: true)
    }

    private func run<T>(_ work: () async throws -> T) async -> T? {
        busy = true
        lastError = nil
        defer { busy = false }
        do {
            return try await work()
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    private func adoptRepo(_ url: URL) {
        let server = url.appendingPathComponent("service/scripts/server.py")
        guard FileManager.default.fileExists(atPath: server.path) else {
            lastError = "That folder does not contain service/scripts/server.py."
            return
        }
        repoPath = url.path
        UserDefaults.standard.set(url.path, forKey: repoDefaultsKey)
        lastError = nil
        Task { await startService() }
    }

    private func locateRepo() {
        let candidates = [
            UserDefaults.standard.string(forKey: repoDefaultsKey),
            ProcessInfo.processInfo.environment["WATERMARKS_REPO"],
        ].compactMap { $0 }
        for path in candidates where Self.isRepo(path) {
            repoPath = path
            return
        }
        var url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        for _ in 0..<8 {
            if Self.isRepo(url.path) {
                repoPath = url.path
                return
            }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { break }
            url = parent
        }
    }

    private func getHealth() async throws -> HealthBody {
        var request = URLRequest(url: baseURL.appendingPathComponent("health"))
        request.timeoutInterval = 2
        Self.authorize(&request)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw ServiceFailure("Health check failed.")
        }
        return try JSONDecoder().decode(HealthBody.self, from: data)
    }

    private func post(path: String, body: Data) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120
        request.httpBody = body
        Self.authorize(&request)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ServiceFailure("The service returned an unexpected response.")
        }
        return (data, http)
    }

    private static func fileBody(data: Data, name: String) throws -> Data {
        let payload: [String: String] = [
            "file": data.base64EncodedString(),
            "name": name,
        ]
        return try JSONSerialization.data(withJSONObject: payload)
    }

    private static func authorize(_ request: inout URLRequest) {
        if let key = ProcessInfo.processInfo.environment["WATERMARKS_SERVER_API_KEY"], !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
    }

    private static func pythonExecutable() -> String {
        for path in ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]
            where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return "/usr/bin/env"
    }

    private static func isRepo(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: (path as NSString).appendingPathComponent("service/scripts/server.py"))
    }

    private static func jsonObject(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ServiceFailure("The service returned JSON that was not an object.")
        }
        return object
    }

    private static func throwIfNeeded(_ data: Data, status: Int) throws {
        guard status >= 400 else { return }
        let message = (try? jsonObject(data)["error"] as? String) ?? "Request failed (\(status))."
        throw ServiceFailure(message)
    }

    private static func decode<T: Decodable>(_ type: T.Type, from value: Any?) -> T? {
        guard let value, JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func inspectDetail(report: [String: Any]?, suspicious: SuspiciousReport?) -> String {
        var lines: [String] = []
        if let total = report?["suspicious_total"] as? Int {
            lines.append("Suspicious marks: \(total)")
        }
        if let hits = report?["hits"] as? [[String: Any]] {
            for hit in hits.prefix(8) {
                let label = hit["label"] as? String ?? "mark"
                let count = hit["count"] as? Int ?? 0
                lines.append("\(label) × \(count)")
            }
        }
        if lines.isEmpty, let suspicious {
            lines.append(suspicious.summary)
        }
        return lines.joined(separator: "\n")
    }

    private static func cleanSummary(report: [String: Any]?, bytes: Int) -> String {
        if let stats = report?["stats"] as? [String: Any], let removed = stats["removed_count"] as? Int {
            return "Removed \(removed) marks. \(bytes) bytes out."
        }
        if let actions = report?["actions"] as? [String], !actions.isEmpty {
            return actions.prefix(6).joined(separator: "\n")
        }
        return "Cleaned file is \(bytes) bytes."
    }

    private static func isLayerBRefusal(_ message: String) -> Bool {
        message.contains("Layer B") || message.contains("WATERMARKS_REWRITE")
    }

    private static func looksLikeText(name: String, data: Data) -> Bool {
        let textExtensions = ["txt", "md", "markdown", "html", "htm", "csv", "json"]
        let ext = (name as NSString).pathExtension.lowercased()
        if textExtensions.contains(ext) { return true }
        return String(data: data, encoding: .utf8) != nil && !data.contains(0)
    }

    private static func layerACleanSync(repo: String, text: String) throws -> (Data, String) {
        let process = Process()
        process.currentDirectoryURL = URL(fileURLWithPath: repo)
        let python = pythonExecutable()
        if python == "/usr/bin/env" {
            process.executableURL = URL(fileURLWithPath: python)
            process.arguments = ["python3", "service/scripts/clean_text.py", "-", "--stats"]
        } else {
            process.executableURL = URL(fileURLWithPath: python)
            process.arguments = ["service/scripts/clean_text.py", "-", "--stats"]
        }
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        input.fileHandleForWriting.write(Data(text.utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        let stdout = output.fileHandleForReading.readDataToEndOfFile()
        let stderr = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if process.terminationStatus != 0 {
            throw ServiceFailure(stderr.isEmpty ? "clean_text.py failed." : stderr)
        }
        return (stdout, stderr)
    }

    private static func removedCount(fromStats stderr: String) -> Int? {
        guard let data = stderr.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["removed_count"] as? Int
    }
}

private struct HealthBody: Decodable {
    let ok: Bool
    let version: String?
}

struct ServiceFailure: LocalizedError, Sendable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
