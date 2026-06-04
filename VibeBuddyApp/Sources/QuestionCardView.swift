import SwiftUI
import VibeBuddyKit

struct QuestionCardView: View {
    let question: PendingQuestion
    let answer: (String) -> Void
    @State private var customAnswer = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Question", systemImage: "questionmark.bubble")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
            Text(question.prompt)
                .font(.subheadline)
                .foregroundStyle(.primary)
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
                                        .font(.subheadline.weight(.semibold))
                                    if let description = option.description {
                                        Text(description)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }
                                }
                                Spacer(minLength: 8)
                                Image(systemName: "arrow.turn.down.left")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
        }
        .padding(10)
        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 8))
    }

    private var manualAnswer: some View {
        HStack(spacing: 8) {
            TextField("Answer", text: $customAnswer, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...3)
            Button {
                let trimmed = customAnswer.trimmingCharacters(in: .whitespacesAndNewlines)
                answer(trimmed)
                customAnswer = ""
            } label: {
                Image(systemName: "arrow.up.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(customAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
}
