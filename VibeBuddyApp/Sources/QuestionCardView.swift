import SwiftUI
import VibeBuddyKit

/// The agent's question(s), answered in place. One single-select question
/// sends on tap; several questions, a multi-select, or a typed "Other" reply
/// collect first and send together.
struct QuestionCardView: View {
    let question: PendingQuestion
    let answer: (QuestionAnswers) -> Void

    @State private var picked: [String: Set<String>] = [:]
    @State private var typed: [String: String] = [:]

    private var items: [QuestionItem] { question.items }
    private var sendsOnTap: Bool {
        items.count == 1 && !items[0].multiSelect && !items[0].options.isEmpty
    }
    /// A typed "Other" reply needs a way out even when options send on tap.
    private var hasTypedText: Bool {
        items.contains { !(typed[$0.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
    private var showsSendButton: Bool { !sendsOnTap || hasTypedText }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
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
                    Text(item.text)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    if item.multiSelect {
                        Text("Choose any").font(.caption2).foregroundStyle(.tertiary)
                    }
                    ForEach(item.options) { option in
                        Button { choose(option, in: item) } label: {
                            HStack(spacing: 8) {
                                Image(systemName: isPicked(option, in: item) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(isPicked(option, in: item) ? Color.accentColor : Color.secondary)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(option.label).font(.subheadline.weight(.semibold))
                                    if let description = option.description {
                                        Text(description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                    }
                                }
                                Spacer(minLength: 8)
                                if sendsOnTap {
                                    Image(systemName: "arrow.turn.down.left")
                                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.bordered)
                    }
                    if item.allowsOther {
                        TextField(item.options.isEmpty ? "Answer" : "Other…", text: binding(for: item.id), axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .lineLimit(1...3)
                            .onSubmit { if complete { send() } }
                    }
                }
            }
            if showsSendButton {
                Button {
                    send()
                } label: {
                    Label("Send answer\(items.count > 1 ? "s" : "")", systemImage: "arrow.up.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!complete)
            }
        }
        .padding(10)
        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 8))
        .onChange(of: question.id) { _, _ in picked = [:]; typed = [:] }
    }

    private func isPicked(_ option: QuestionOption, in item: QuestionItem) -> Bool {
        picked[item.id]?.contains(option.value) == true
    }

    private func choose(_ option: QuestionOption, in item: QuestionItem) {
        if sendsOnTap {
            answer([item.id: [option.value]])
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

    private var complete: Bool { items.allSatisfy { values(for: $0) != nil } }

    private func values(for item: QuestionItem) -> [String]? {
        let text = (typed[item.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var values = Array(picked[item.id] ?? []).sorted { a, b in
            (item.options.firstIndex { $0.value == a } ?? 0) < (item.options.firstIndex { $0.value == b } ?? 0)
        }
        if !text.isEmpty { values.append(text) }
        return values.isEmpty ? nil : values
    }

    private func send() {
        var answers: QuestionAnswers = [:]
        for item in items { if let v = values(for: item) { answers[item.id] = v } }
        guard !answers.isEmpty else { return }
        answer(answers)
        picked = [:]
        typed = [:]
    }
}
