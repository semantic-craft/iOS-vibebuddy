import AppKit
import SwiftUI
import VibeBuddyMacCore
import Darwin

@MainActor final class ReaderFixture: ObservableObject {
    @Published var rows: [HistoryMessageRow] = (0..<152).map { makeRow($0) }
    @Published var target: String? = CommandLine.arguments.contains("--tail") ? nil : "fixture-0"
    static func makeRow(_ index: Int) -> HistoryMessageRow {
        .standalone(id: "fixture-\(index)", role: index % 5 == 0 ? .user : .assistant, text: """
        ## Message \(index)
        This synthetic conversation measures the actual reader with **formatted text**, `inline code`, and a [reference](https://example.com).

        - Check the current snapshot and its visible state.
        - Keep earlier messages accessible while new messages arrive.
        - 中文段落用于验证混合语言布局与换行行为，阅读时应保持位置稳定。

        ```swift
        struct Snapshot {
            let messageCount = \(index)
            let isFollowing = false
        }
        ```

        > A quoted paragraph keeps the Markdown layout representative of an engineering conversation.

        | Item | State |
        | --- | --- |
        | Reader | Ready |
        | Message | \(index) |
        """)
    }
    func append() { rows.append(Self.makeRow(rows.count)) }
}

struct ReaderBenchmarkView: View {
    @ObservedObject var fixture: ReaderFixture
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Synthetic reader QA · \(fixture.rows.count) rows")
                Button("First match") { fixture.target = "fixture-0" }
                Button("Middle match") { fixture.target = "fixture-75" }
                Button("Latest") { fixture.target = nil }
                Button("Append") { fixture.append() }
            }.padding(10)
            Divider()
            SessionReaderView(rows: fixture.rows, targetMessage: fixture.target, note: "Synthetic fixture; no user transcript or production daemon") {
                Text("Reader benchmark").font(.headline)
            } tail: {
                Text("End of fixture").accessibilityIdentifier("fixture-end")
            }
        }.frame(width: 820, height: 760)
    }
}

@MainActor final class BenchmarkDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    let fixture = ReaderFixture()
    var timer: Timer?
    let started = Date()
    var initialCPU: Double = 0
    func cpu() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        initialCPU = cpu()
        window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 820, height: 760), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Reader performance QA"
        window.contentView = NSHostingView(rootView: ReaderBenchmarkView(fixture: fixture))
        window.orderFront(nil)
        let interactive = CommandLine.arguments.contains("--interactive")
        var ticks = 0
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                ticks += 1
                print("READER_METRIC tick=\(ticks) wall=\(Date().timeIntervalSince(self.started)) cpu=\(self.cpu() - self.initialCPU) rows=\(self.fixture.rows.count)")
                fflush(stdout)
                if !interactive {
                    if ticks >= 3 && ticks <= 8 { self.fixture.append() }
                    if ticks >= 12 { NSApp.terminate(nil) }
                }
            }
        }
    }
}

@main struct ReaderBenchmark {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = BenchmarkDelegate()
        app.setActivationPolicy(.regular)
        app.delegate = delegate
        app.run()
        withExtendedLifetime(delegate) {}
    }
}
