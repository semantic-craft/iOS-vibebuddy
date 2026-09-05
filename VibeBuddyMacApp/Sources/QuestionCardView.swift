import SwiftUI
import VibeBuddyKit

/// The agent's question(s) on the Mac detail pane, answered in place: tap an
/// option (single-select, single question) to send at once; otherwise pick
/// per question, type an "Other" reply where allowed, and send.
struct QuestionCardView: View {
    let question: PendingQuestion
    let onAnswer: (QuestionAnswers) -> Void

    @State private var picked: [String: Set<String>] = [:]
    @State private var typed: [String: String] = [:]

    private var items: [QuestionItem] { question.items }
    private var sendsOnTap: Bool {
        items.count == 1 && !(items[0].multiSelect) && !items[0].options.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(items.count > 1 ? "\(items.count) questions" : "Question", systemImage: "questionmark.bubble")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color(taskStatus: TaskPresentationState.requiresInput.colorToken))
            if question.isBlocking == false, let expires = question.expiresAt {
                Text("Codex moves on by itself in \(expires, style: .timer)")
                    .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
            }
            ForEach(items) { item in
                VStack(alignment: .leading, spacing: 6) {
                    if let header = item.header, items.count > 1 {
                        Text(header).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    Text(item.text).font(.body).fixedSize(horizontal: false, vertical: true)
                    if item.multiSelect { Text("Choose any").font(.caption2).foregroundStyle(.tertiary) }
                    ForEach(item.options) { option in
                        Button { choose(option, in: item) } label: {
                            HStack(spacing: 8) {
                                Image(systemName: isPicked(option, in: item) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(isPicked(option, in: item) ? Color.accentColor : Color.secondary)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(option.label).fontWeight(.semibold)
                                    if let description = option.description {
                                        Text(description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                    }
                                }
                                Spacer(minLength: 8)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.bordered)
                    }
                    if item.allowsOther {
                        TextField(item.options.isEmpty ? "Your answer" : "Other…",
                                  text: binding(for: item.id), axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .lineLimit(1...4)
                            .onSubmit { if sendsOnTap || items.count == 1 { send() } }
                    }
                }
            }
            if !sendsOnTap {
                Button("Send answer\(items.count > 1 ? "s" : "")") { send() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!complete)
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 8))
        .onChange(of: question.id) { _, _ in picked = [:]; typed = [:] }
    }

    private func isPicked(_ option: QuestionOption, in item: QuestionItem) -> Bool {
        picked[item.id]?.contains(option.value) == true
    }

    private func choose(_ option: QuestionOption, in item: QuestionItem) {
        if sendsOnTap {
            onAnswer([item.id: [option.value]])
            return
        }
        var set = picked[item.id] ?? []
        if item.multiSelect {
            if set.contains(option.value) { set.remove(option.value) } else { set.insert(option.value) }
        } else {
            set = [option.value]
        }
        picked[item.id] = set
    }

    private func binding(for id: String) -> Binding<String> {
        Binding(get: { typed[id] ?? "" }, set: { typed[id] = $0 })
    }

    /// Every question has a pick or a typed reply.
    private var complete: Bool {
        items.allSatisfy { answer(for: $0) != nil }
    }

    private func answer(for item: QuestionItem) -> [String]? {
        let text = (typed[item.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var values = Array(picked[item.id] ?? []).sorted { a, b in
            (item.options.firstIndex { $0.value == a } ?? 0) < (item.options.firstIndex { $0.value == b } ?? 0)
        }
        if !text.isEmpty { values.append(text) }
        return values.isEmpty ? nil : values
    }

    private func send() {
        var answers: QuestionAnswers = [:]
        for item in items { if let values = answer(for: item) { answers[item.id] = values } }
        guard !answers.isEmpty else { return }
        onAnswer(answers)
        picked = [:]
        typed = [:]
    }
}
