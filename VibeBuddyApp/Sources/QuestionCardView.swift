import SwiftUI
import VibeBuddyKit

/// A question the agent asked, Companion style: the prompt as the line that
/// matters, the offered answers as soft pills, or a free-text reply.
struct QuestionCardView: View {
    let question: PendingQuestion
    let answer: (String) -> Void
    @State private var customAnswer = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Question")
                .font(CompanionType.font(10, .heavy)).textCase(.uppercase).kerning(0.6)
                .foregroundStyle(CompanionPalette.status(.requiresInput))
            Text(question.prompt)
                .font(CompanionType.font(14, .heavy))
                .foregroundStyle(CompanionPalette.ink)
                .fixedSize(horizontal: false, vertical: true)
            if question.options.isEmpty {
                manualAnswer
            } else {
                VStack(spacing: 6) {
                    ForEach(question.options) { option in
                        Button {
                            answer(option.value)
                        } label: {
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(option.label)
                                    if let description = option.description {
                                        Text(description)
                                            .font(CompanionType.font(11, .semibold))
                                            .foregroundStyle(CompanionPalette.ink2)
                                            .lineLimit(2)
                                    }
                                }
                                Spacer(minLength: 8)
                                Image(systemName: "arrow.turn.down.left")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(CompanionPalette.ink3)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(PillButtonStyle(kind: .soft))
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CompanionPalette.bg2, in: RoundedRectangle(cornerRadius: CompanionType.cardRadius, style: .continuous))
    }

    private var manualAnswer: some View {
        HStack(spacing: 8) {
            TextField("Answer", text: $customAnswer, axis: .vertical)
                .font(CompanionType.font(13, .semibold))
                .lineLimit(1...3)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(CompanionPalette.bg3, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            Button {
                let trimmed = customAnswer.trimmingCharacters(in: .whitespacesAndNewlines)
                answer(trimmed)
                customAnswer = ""
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 14, weight: .black))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(CompanionPalette.accent, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(customAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel("Send answer")
        }
    }
}
