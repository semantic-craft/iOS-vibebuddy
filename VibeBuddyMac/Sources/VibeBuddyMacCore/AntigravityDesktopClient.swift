import Darwin
import Foundation
import Security

/// Native desktop identity; titles and workspace paths are display facts only.
public struct AntigravityDesktopConversation: Sendable, Equatable {
    public let id: String
    public let title: String?
    public let status: String
    public let stepCount: Int
    public var workspace: String?
    public var updatedAt: Date?
    public var turnID: String?
    public var source: String

    public init(id: String, title: String?, status: String, stepCount: Int,
                workspace: String? = nil, updatedAt: Date? = nil, turnID: String? = nil, source: String = "Desktop") {
        self.id = id; self.title = title; self.status = status; self.stepCount = stepCount
        self.workspace = workspace; self.updatedAt = updatedAt; self.turnID = turnID; self.source = source
    }
}

public enum AntigravityDesktopError: Error { case unavailable, invalidResponse, oversizedResponse, transport(Int), malformedList }

/// This client exposes only the two read-only native RPCs. Credentials stay in
/// memory; no arbitrary URL, RPC name, OAuth token or external host is accepted.
public actor AntigravityDesktopClient {
    private struct Endpoint: Sendable { let port: Int; let csrf: String; let source: String }
    private var endpoints: [Endpoint] = []
    private var endpointByConversation: [String: Endpoint] = [:]
    private var discoveredAt = Date.distantPast
    public init() {}

    public func conversations() async throws -> [AntigravityDesktopConversation] {
        if Date().timeIntervalSince(discoveredAt) > 30 || endpoints.isEmpty {
            endpoints = try await Self.discover()
            discoveredAt = Date()
        }
        var conversations: [String: AntigravityDesktopConversation] = [:]
        var responsive: [Endpoint] = []
        var answered = false
        var lastFailure = AntigravityDesktopError.unavailable
        for endpoint in endpoints.prefix(12) {
            let data: Data
            do { data = try await request("GetAllCascadeTrajectories", body: [:], endpoint: endpoint) }
            catch { lastFailure = (error as? AntigravityDesktopError) ?? .transport((error as NSError).code); continue }
            guard let list = try? JSONDecoder().decode(ListResponse.self, from: data) else {
                lastFailure = .malformedList; continue
            }
            answered = true
            responsive.append(endpoint)
            for (id, value) in list.trajectorySummaries {
                guard id.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil else { continue }
                let conversation = AntigravityDesktopConversation(id: id, title: value.summary,
                    status: value.status ?? "UNKNOWN", stepCount: max(0, value.stepCount ?? 0),
                    workspace: value.workspaces?.first?.workspaceFolderAbsoluteUri.flatMap { URL(string: $0)?.path },
                    updatedAt: Self.date(value.lastModifiedTime), turnID: value.lastUserInputTime, source: endpoint.source)
                if let previous = conversations[id],
                   (previous.updatedAt ?? .distantPast) > (conversation.updatedAt ?? .distantPast) { continue }
                conversations[id] = conversation
                endpointByConversation[id] = endpoint
            }
        }
        guard answered else {
            discoveredAt = .distantPast
            throw lastFailure
        }
        endpoints = responsive
        return conversations.values.sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
    }

    public func steps(for conversation: AntigravityDesktopConversation) async throws -> AntigravityDesktopSteps {
        guard let selected = endpointByConversation[conversation.id] else { throw AntigravityDesktopError.unavailable }
        // Only the current tail is needed for state. Conversation reading uses
        // the native full transcript, independently of this bounded query.
        let data = try await request("GetCascadeTrajectorySteps", body: [
            "cascadeId": conversation.id, "startIndex": max(0, conversation.stepCount - 128),
            "endIndex": conversation.stepCount
        ], endpoint: selected)
        return try JSONDecoder().decode(AntigravityDesktopSteps.self, from: data)
    }

    private func request(_ method: String, body: [String: Any], endpoint: Endpoint) async throws -> Data {
        guard ["GetAllCascadeTrajectories", "GetCascadeTrajectorySteps"].contains(method),
              (1...65535).contains(endpoint.port) else { throw AntigravityDesktopError.invalidResponse }
        let url = URL(string: "https://127.0.0.1:\(endpoint.port)/exa.language_server_pb.LanguageServerService/\(method)")!
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 3
        configuration.timeoutIntervalForResource = 5
        let delegate = LoopbackDelegate(port: endpoint.port)
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.setValue(endpoint.csrf, forHTTPHeaderField: "X-Codeium-Csrf-Token")
        let (bytes, response) = try await session.bytes(for: request, delegate: delegate)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              response.url == url else { throw AntigravityDesktopError.invalidResponse }
        let maximum = 8 * 1024 * 1024
        guard response.expectedContentLength <= maximum else { throw AntigravityDesktopError.oversizedResponse }
        var data = Data()
        for try await byte in bytes {
            guard data.count < maximum else { throw AntigravityDesktopError.oversizedResponse }
            data.append(byte)
        }
        return data
    }

    private static func discover() async throws -> [Endpoint] {
        let listing = try await command("/bin/ps", ["-ww", "-U", String(getuid()), "-o", "uid=,pid=,args="])
        var result: [Endpoint] = []
        for line in String(decoding: listing, as: UTF8.self).split(separator: "\n") {
            let fields = line.split(maxSplits: 2, whereSeparator: { $0.isWhitespace })
            guard fields.count == 3, UInt32(fields[0]) == getuid(), let pid = Int(fields[1]) else { continue }
            let args = String(fields[2])
            // Validate the kernel's executable path, not a bundle name a
            // different process could merely include in its argument text.
            var executable = [CChar](repeating: 0, count: 4096)
            guard proc_pidpath(Int32(pid), &executable, UInt32(executable.count)) > 0 else { continue }
            let path = String(decoding: executable.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            guard path.contains("/language_server"),
                  path.contains("/Antigravity.app/") || path.contains("/Antigravity IDE.app/") else { continue }
            guard let regex = try? NSRegularExpression(pattern: #"--csrf_token(?:=|\s+)(\S+)"#),
                  let match = regex.firstMatch(in: args, range: NSRange(args.startIndex..., in: args)),
                  let range = Range(match.range(at: 1), in: args) else { continue }
            let token = String(args[range])
            let sockets = try await command("/usr/sbin/lsof", ["-nP", "-a", "-p", String(pid), "-iTCP", "-sTCP:LISTEN", "-Fn"])
            for socket in String(decoding: sockets, as: UTF8.self).split(separator: "\n") where socket.hasPrefix("n") {
                guard let colon = socket.lastIndex(of: ":"), let port = Int(socket[socket.index(after: colon)...]),
                      (1...65535).contains(port), !result.contains(where: { $0.port == port }) else { continue }
                result.append(Endpoint(port: port, csrf: token, source: path.contains("/Antigravity IDE.app/") ? "IDE" : "Desktop"))
            }
        }
        return result
    }

    private static func command(_ path: String, _ args: [String]) async throws -> Data {
        let supervisor = try POSIXCommandSupervisor()
        return try await withTaskCancellationHandler {
            try await Task.detached {
                try supervisor.run(executableURL: URL(fileURLWithPath: path), arguments: args,
                    environment: ["PATH": "/usr/bin:/bin:/usr/sbin"], timeout: 3,
                    outputLimit: 4 * 1024 * 1024).standardOutput
            }.value
        } onCancel: { supervisor.cancel() }
    }

    private static func date(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
    }

    private struct ListResponse: Decodable {
        let trajectorySummaries: [String: Summary]
        struct Summary: Decodable {
            let summary: String?; let status: String?; let stepCount: Int?
            let lastModifiedTime: String?; let lastUserInputTime: String?
            let workspaces: [Workspace]?
        }
        struct Workspace: Decodable { let workspaceFolderAbsoluteUri: String? }
    }
}

private final class LoopbackDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    let port: Int
    init(port: Int) { self.port = port }
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        guard space.host == "127.0.0.1", space.port == port,
              space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = space.serverTrust else { completionHandler(.cancelAuthenticationChallenge, nil); return }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        urlSession(session, didReceive: challenge, completionHandler: completionHandler)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
