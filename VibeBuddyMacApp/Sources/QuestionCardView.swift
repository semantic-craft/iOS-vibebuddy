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
            Text(items.count > 1 ? "\(items.count) questions" : "Question")
                .font(MacTheme.font(10, .heavy)).textCase(.uppercase).kerning(0.6)
                .foregroundStyle(MacTheme.status(.requiresInput))
            if question.isBlocking == false, let expires = question.expiresAt {
                Text("Codex moves on by itself in \(expires, style: .timer)")
                    .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
            }
            ForEach(items) { item in
                VStack(alignment: .leading, spacing: 6) {
                    if let header = item.header, items.count > 1 {
                        Text(header).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    Text(item.text).font(MacTheme.font(14, .heavy)).foregroundStyle(MacTheme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    if item.multiSelect { Text("Choose any").font(.caption2).foregroundStyle(.tertiary) }
                    ForEach(item.options) { option in
                        Button { choose(option, in: item) } label: {
                            HStack(spacing: 8) {
                                Image(systemName: isPicked(option, in: item) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(isPicked(option, in: item) ? MacTheme.accent : MacTheme.ink3)
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
                        .buttonStyle(PillButtonStyle(kind: .soft, size: .small))
                    }
                    if item.allowsOther {
                        TextField(item.options.isEmpty ? "Your answer" : "Other…",
                                  text: binding(for: item.id), axis: .vertical)
                            .textFieldStyle(.plain)
                            .font(MacTheme.font(13, .semibold))
                            .lineLimit(1...4)
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(MacTheme.bg3, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .onSubmit { if sendsOnTap || items.count == 1 { send() } }
                    }
                }
            }
            if !sendsOnTap {
                Button("Send answer\(items.count > 1 ? "s" : "")") { send() }
                    .buttonStyle(PillButtonStyle(kind: .filled(MacTheme.accent)))
                    .disabled(!complete)
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MacTheme.bg2, in: RoundedRectangle(cornerRadius: MacTheme.cardRadius, style: .continuous))
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
