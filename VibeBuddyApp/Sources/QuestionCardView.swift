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
            Text(items.count > 1 ? "\(items.count) questions" : "Question")
                .font(CompanionType.font(10, .heavy)).textCase(.uppercase).kerning(0.6)
                .foregroundStyle(CompanionPalette.status(.requiresInput))
            if question.isBlocking == false, let expires = question.expiresAt {
                Text("Codex moves on by itself in \(expires, style: .timer)")
                    .font(CompanionType.font(10, .semibold)).foregroundStyle(CompanionPalette.ink3).monospacedDigit()
            }
            ForEach(items) { item in
                VStack(alignment: .leading, spacing: 6) {
                    if let header = item.header, items.count > 1 {
                        Text(header).font(CompanionType.font(11, .heavy)).foregroundStyle(CompanionPalette.ink2)
                    }
                    Text(item.text)
                        .font(CompanionType.font(14, .heavy))
                        .foregroundStyle(CompanionPalette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    if item.multiSelect {
                        Text("Choose any").font(CompanionType.font(10, .semibold)).foregroundStyle(CompanionPalette.ink3)
                    }
                    ForEach(item.options) { option in
                        Button { choose(option, in: item) } label: {
                            HStack(spacing: 8) {
                                if !sendsOnTap {
                                    Image(systemName: isPicked(option, in: item) ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(isPicked(option, in: item) ? CompanionPalette.accent : CompanionPalette.ink3)
                                }
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(option.label)
                                    if let description = option.description {
                                        Text(description).font(CompanionType.font(11, .semibold))
                                            .foregroundStyle(CompanionPalette.ink2).lineLimit(2)
                                    }
                                }
                                Spacer(minLength: 8)
                                if sendsOnTap {
                                    Image(systemName: "arrow.turn.down.left")
                                        .font(.caption.weight(.bold)).foregroundStyle(CompanionPalette.ink3)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(PillButtonStyle(kind: .soft))
                    }
                    if item.allowsOther {
                        TextField(item.options.isEmpty ? "Answer" : "Other…", text: binding(for: item.id), axis: .vertical)
                            .font(CompanionType.font(13, .semibold))
                            .lineLimit(1...3)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(CompanionPalette.bg3, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .onSubmit { if complete { send() } }
                    }
                }
            }
            if showsSendButton {
                Button {
                    send()
                } label: {
                    Label("Send answer\(items.count > 1 ? "s" : "")", systemImage: "arrow.up")
                }
                .buttonStyle(PillButtonStyle(kind: .filled(CompanionPalette.accent), size: .large))
                .disabled(!complete)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CompanionPalette.bg2, in: RoundedRectangle(cornerRadius: CompanionType.cardRadius, style: .continuous))
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
