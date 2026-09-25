import CloudKit
import Foundation
import Network

// CueProtoMac — the Mac half of public-push ticket 01.
//
//   CueProtoMac status
//   CueProtoMac run --out DIR [--count 20] [--interval 30] [--kind approval]
//                   [--burst] [--same-session] [--tail 90] [--port 9878] [--token T]
//   CueProtoMac listen --out DIR [--seconds 600]
//   CueProtoMac report --out DIR
//   CueProtoMac cleanup
//
// `run` saves one `Cue` per interval into the user's private database, reads
// back the phone's `Receipt` / `Action` / `Delivered` records through zone
// changes, deletes each cue once its receipt arrives, and serves `/time` and
// `/action` for the phone on the LAN. Every event is one JSON line in
// DIR/events.jsonl; `report` turns that into the latency table.

setvbuf(stdout, nil, _IOLBF, 0)

struct Options {
    var command = "status"
    var out = FileManager.default.currentDirectoryPath
    var count = 20
    var interval = 30.0
    var kind = "approval"
    var burst = false
    var sameSession = false
    var tail = 90.0
    var port: UInt16 = 9878
    var token = ProcessInfo.processInfo.environment["CUEPROTO_TOKEN"] ?? ""
    var seconds = 600.0

    init(_ args: [String]) {
        var it = args.dropFirst().makeIterator()
        if let first = it.next() { command = first }
        while let flag = it.next() {
            switch flag {
            case "--out": out = it.next() ?? out
            case "--count": count = Int(it.next() ?? "") ?? count
            case "--interval": interval = Double(it.next() ?? "") ?? interval
            case "--kind": kind = it.next() ?? kind
            case "--burst": burst = true
            case "--same-session": sameSession = true
            case "--tail": tail = Double(it.next() ?? "") ?? tail
            case "--port": port = UInt16(it.next() ?? "") ?? port
            case "--token": token = it.next() ?? token
            case "--seconds": seconds = Double(it.next() ?? "") ?? seconds
            default: print("unknown flag \(flag)"); exit(2)
            }
        }
    }
}

final class EventLog: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()

    init(dir: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        url = URL(fileURLWithPath: dir).appendingPathComponent("events.jsonl")
    }

    func write(_ fields: [String: Any]) {
        var line = fields
        line["macAt"] = Date().timeIntervalSince1970
        guard let data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]) else { return }
        lock.lock(); defer { lock.unlock() }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile(); handle.write(data); handle.write(Data("\n".utf8)); try? handle.close()
        } else {
            try? (data + Data("\n".utf8)).write(to: url)
        }
        print(String(data: data, encoding: .utf8)!)
    }

    func read() -> [[String: Any]] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
    }
}

// MARK: - LAN listener (stands in for the shipping bearer routes)

final class Listener: @unchecked Sendable {
    private let listener: NWListener
    private let log: EventLog
    private let token: String

    init(port: UInt16, token: String, log: EventLog) throws {
        listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
        self.log = log
        self.token = token
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        listener.start(queue: .global())
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: .global())
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, _, _ in
            guard let self, let data, let text = String(data: data, encoding: .utf8) else { connection.cancel(); return }
            let head = text.components(separatedBy: "\r\n\r\n").first ?? ""
            let body = text.components(separatedBy: "\r\n\r\n").dropFirst().joined(separator: "\r\n\r\n")
            let requestLine = head.components(separatedBy: "\r\n").first ?? ""
            let authorized = head.range(of: "Authorization: Bearer \(self.token)", options: .caseInsensitive) != nil && !self.token.isEmpty
            var status = "200 OK"
            var reply = "{}"
            if !authorized {
                status = "401 Unauthorized"
                self.log.write(["event": "http-unauthorized", "request": requestLine])
            } else if requestLine.hasPrefix("GET /time") {
                reply = "{\"now\":\(Date().timeIntervalSince1970)}"
            } else if requestLine.hasPrefix("POST /action") {
                var fields = (try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any]) ?? [:]
                fields["event"] = "action-http"
                self.log.write(fields)
            } else {
                status = "404 Not Found"
            }
            let response = "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(reply.utf8.count)\r\nConnection: close\r\n\r\n\(reply)"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}

// MARK: - CloudKit

func ensureZone() async throws {
    _ = try await CueProto.database.modifyRecordZones(saving: [CKRecordZone(zoneID: CueProto.zoneID)], deleting: [])
}

/// Reads the phone's records as zone changes (no query indexes needed).
actor ZoneReader {
    private var token: CKServerChangeToken?
    private var seen = Set<String>()
    let log: EventLog

    init(log: EventLog) { self.log = log }

    /// Returns the cue record names whose receipt arrived in this batch.
    func poll() async throws -> [CKRecord.ID] {
        var receipted: [CKRecord.ID] = []
        var more = true
        while more {
            let changes = try await CueProto.database.recordZoneChanges(inZoneWith: CueProto.zoneID, since: token)
            for (id, result) in changes.modificationResultsByID {
                guard case .success(let modification) = result, !seen.contains(id.recordName) else { continue }
                let record = modification.record
                switch record.recordType {
                case CueProto.receiptType:
                    seen.insert(id.recordName)
                    let cueID = record["cueID"] as? String ?? "?"
                    log.write([
                        "event": "receipt", "cueID": cueID,
                        "startedAt": (record["startedAt"] as? Date)?.timeIntervalSince1970 ?? 0,
                        "handedAt": (record["handedAt"] as? Date)?.timeIntervalSince1970 ?? 0,
                        "locked": record["locked"] as? Int ?? -1, "detailOK": record["detailOK"] as? Int ?? -1,
                        "fetchMs": record["fetchMs"] as? Double ?? -1, "fetchError": record["fetchError"] as? String ?? "",
                        // Server clock: skew-free upper bound together with the cue's.
                        "serverCreated": record.creationDate?.timeIntervalSince1970 ?? 0,
                    ])
                    receipted.append(CKRecord.ID(recordName: cueID, zoneID: CueProto.zoneID))
                case CueProto.actionType:
                    seen.insert(id.recordName)
                    log.write([
                        "event": "action-record", "cueID": record["cueID"] as? String ?? "?",
                        "action": record["action"] as? String ?? "", "appState": record["appState"] as? Int ?? -1,
                        "receivedAt": (record["receivedAt"] as? Date)?.timeIntervalSince1970 ?? 0,
                        "macPost": record["macPost"] as? String ?? "",
                    ])
                case CueProto.deviceType:
                    // Re-registrations overwrite the same record; log every version.
                    let key = "\(id.recordName)@\(record.recordChangeTag ?? "")"
                    guard !seen.contains(key) else { continue }
                    seen.insert(key)
                    log.write([
                        "event": "device", "name": record["name"] as? String ?? "",
                        "userRecordName": record["userRecordName"] as? String ?? "",
                        "clockOffset": record["clockOffset"] as? Double ?? .nan,
                        "clockRTT": record["clockRTT"] as? Double ?? .nan,
                        "registeredAt": (record["registeredAt"] as? Date)?.timeIntervalSince1970 ?? .nan,
                        "serverModified": record.modificationDate?.timeIntervalSince1970 ?? .nan,
                    ].filter { !(($0.value as? Double)?.isNaN ?? false) })
                case CueProto.deliveredType:
                    seen.insert(id.recordName)
                    log.write([
                        "event": "delivered", "rows": record["rows"] as? String ?? "[]",
                        "log": record["log"] as? String ?? "",
                        "uploadedAt": (record["uploadedAt"] as? Date)?.timeIntervalSince1970 ?? 0,
                    ])
                default:
                    break
                }
            }
            token = changes.changeToken
            more = changes.moreComing
        }
        return receipted
    }
}

func status() async throws {
    let container = CueProto.container
    let account = try await container.accountStatus()
    let user = try await container.userRecordID()
    print("accountStatus=\(account.rawValue) (1 = available) userRecordName=\(user.recordName)")
    try await ensureZone()
    let subs = try await CueProto.database.allSubscriptions()
    print("subscriptions on this account: \(subs.map(\.subscriptionID))")
    let reader = ZoneReader(log: EventLog(dir: NSTemporaryDirectory()))
    _ = try await reader.poll()
}

func makeCue(index: Int, tag: String, opts: Options) -> CKRecord {
    let cueID = "\(tag)-\(index)"
    let record = CKRecord(recordType: CueProto.cueType, recordID: CKRecord.ID(recordName: cueID, zoneID: CueProto.zoneID))
    record["cueID"] = cueID
    record["kind"] = opts.kind
    record["project"] = "vibebuddy"
    record["sessionKey"] = opts.sameSession ? "\(tag)-session" : cueID
    record["sentAt"] = Date()
    record.encryptedValues["detail"] = "Bash: swift test --filter Cue\(index) (cue \(cueID))"
    return record
}

func run(_ opts: Options) async throws {
    let log = EventLog(dir: opts.out)
    let listener = try Listener(port: opts.port, token: opts.token, log: log)
    _ = listener
    try await ensureZone()
    let reader = ZoneReader(log: log)
    _ = try await reader.poll() // skip history: start from now
    let tag = "c" + String(Int(Date().timeIntervalSince1970) % 1_000_000)
    log.write(["event": "run-start", "tag": tag, "count": opts.count, "interval": opts.interval, "burst": opts.burst, "sameSession": opts.sameSession, "kind": opts.kind])

    let pollTask = Task {
        while !Task.isCancelled {
            do {
                let done = try await reader.poll()
                if !done.isEmpty {
                    // The push is out; the record has done its job.
                    try? await CueProto.save([], deleting: done)
                    log.write(["event": "cues-deleted", "ids": done.map(\.recordName)])
                }
            } catch {
                log.write(["event": "poll-error", "error": CueProto.describe(error)])
            }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    for index in 0..<opts.count {
        let record = makeCue(index: index, tag: tag, opts: opts)
        let saveStart = Date()
        do {
            let result = try await CueProto.database.modifyRecords(saving: [record], deleting: [], savePolicy: .allKeys, atomically: false)
            let saved = try result.saveResults[record.recordID]!.get()
            log.write(["event": "cue-saved", "cueID": record.recordID.recordName, "saveStart": saveStart.timeIntervalSince1970, "savedAt": Date().timeIntervalSince1970,
                       "serverCreated": saved.creationDate?.timeIntervalSince1970 ?? 0])
        } catch {
            log.write(["event": "cue-save-error", "cueID": record.recordID.recordName, "error": CueProto.describe(error)])
        }
        if !opts.burst, index < opts.count - 1 { try await Task.sleep(for: .seconds(opts.interval)) }
    }
    try await Task.sleep(for: .seconds(opts.tail))
    pollTask.cancel()
    log.write(["event": "run-end", "tag": tag])
}

func listen(_ opts: Options) async throws {
    let log = EventLog(dir: opts.out)
    let listener = try Listener(port: opts.port, token: opts.token, log: log)
    _ = listener
    let reader = ZoneReader(log: log)
    _ = try await reader.poll()
    let end = Date().addingTimeInterval(opts.seconds)
    while Date() < end {
        _ = try? await reader.poll()
        try await Task.sleep(for: .seconds(2))
    }
}

func cleanup() async throws {
    let changes = try await CueProto.database.recordZoneChanges(inZoneWith: CueProto.zoneID, since: nil)
    let cues = changes.modificationResultsByID.compactMap { id, result -> CKRecord.ID? in
        guard case .success(let m) = result, m.record.recordType == CueProto.cueType else { return nil }
        return id
    }
    try await CueProto.save([], deleting: cues)
    print("deleted \(cues.count) leftover cues")
}

// MARK: - Report

func percentile(_ values: [Double], _ p: Double) -> Double {
    guard !values.isEmpty else { return .nan }
    let sorted = values.sorted()
    let rank = Int((p * Double(sorted.count)).rounded(.up)) - 1 // nearest-rank
    return sorted[max(0, min(sorted.count - 1, rank))]
}

func report(_ opts: Options) {
    let events = EventLog(dir: opts.out).read()
    let offset = events.last { $0["event"] as? String == "device" }?["clockOffset"] as? Double ?? 0
    print(String(format: "clock offset (mac − phone) applied: %.3f s", offset))
    var saved: [String: [String: Any]] = [:]
    for e in events where e["event"] as? String == "cue-saved" { saved[e["cueID"] as! String] = e }
    var receipts: [String: [[String: Any]]] = [:]
    for e in events where e["event"] as? String == "receipt" { receipts[e["cueID"] as! String, default: []].append(e) }

    var toStart: [Double] = [], toBanner: [Double] = [], saveMs: [Double] = [], serverBound: [Double] = []
    print("cueID\tsave_ms\tpush→NSE_s\tbanner_s\tlocked\tdetail\tfetch_ms")
    for (cueID, cue) in saved.sorted(by: { ($0.value["savedAt"] as! Double) < ($1.value["savedAt"] as! Double) }) {
        let savedAt = cue["savedAt"] as! Double
        let save = (savedAt - (cue["saveStart"] as! Double)) * 1000
        saveMs.append(save)
        guard let r = receipts[cueID]?.first else {
            print("\(cueID)\t\(Int(save))\tMISSING")
            continue
        }
        let start = (r["startedAt"] as! Double) + offset - savedAt
        let banner = (r["handedAt"] as! Double) + offset - savedAt
        toStart.append(start); toBanner.append(banner)
        if let a = cue["serverCreated"] as? Double, let b = r["serverCreated"] as? Double, a > 0, b > 0 { serverBound.append(b - a) }
        print(String(format: "%@\t%d\t%.2f\t%.2f\t%d\t%d\t%d", cueID, Int(save), start, banner, r["locked"] as? Int ?? -1, r["detailOK"] as? Int ?? -1, Int(r["fetchMs"] as? Double ?? -1)))
    }
    let missing = saved.count - toBanner.count
    print(String(format: "\ncues=%d received=%d missing=%d duplicates=%d", saved.count, toBanner.count, missing, receipts.values.reduce(0) { $0 + max(0, $1.count - 1) }))
    print(String(format: "save→banner  p50=%.2f s  p95=%.2f s  max=%.2f s", percentile(toBanner, 0.5), percentile(toBanner, 0.95), toBanner.max() ?? .nan))
    print(String(format: "server cue→receipt (skew-free upper bound) p50=%.2f s  p95=%.2f s  max=%.2f s", percentile(serverBound, 0.5), percentile(serverBound, 0.95), serverBound.max() ?? .nan))
    print(String(format: "save→NSE     p50=%.2f s  p95=%.2f s", percentile(toStart, 0.5), percentile(toStart, 0.95)))
    print(String(format: "Mac save     p50=%.0f ms p95=%.0f ms", percentile(saveMs, 0.5), percentile(saveMs, 0.95)))
    for e in events where (e["event"] as? String)?.hasPrefix("action") == true { print("action: \(e)") }
    if let delivered = events.last(where: { $0["event"] as? String == "delivered" }), let rows = delivered["rows"] as? String {
        print("last delivered readback: \(rows)")
    }
}

let opts = Options(CommandLine.arguments)
do {
    switch opts.command {
    case "status": try await status()
    case "run": try await run(opts)
    case "listen": try await listen(opts)
    case "report": report(opts)
    case "cleanup": try await cleanup()
    default: print("unknown command \(opts.command)"); exit(2)
    }
} catch {
    print("error: \(CueProto.describe(error))")
    exit(1)
}
