import Foundation

/// Reads text longer than one vendor request by splitting it at sentence ends,
/// synthesizing the pieces two at a time, and joining the MP3s in order.
///
/// A spoken summary is up to 900 characters plus its title, but a single
/// request has to stay short: Doubao took 39 s for 880 characters (past the
/// 15 s request timeout) and Qwen stops after about two minutes of audio. A
/// persona makes this common rather than rare — coquettish and sultry wording
/// runs longer and reads slower.
struct ChunkedSpeechSynthesizer: SpeechSynthesizer {
    static let pieceLimit = 180
    /// Guards against runaway input, not a real summary.
    static let totalLimit = 2_000
    static let maximumBytes = 12_000_000
    /// Two at a time: enough to halve the wait without tripping a low
    /// per-key concurrency quota, which would fail the whole reading.
    static let concurrency = 2

    let base: any SpeechSynthesizer

    func synthesize(_ text: String, apiKey: String) async throws -> Data {
        let pieces = Self.pieces(text)
        guard !pieces.isEmpty, text.count <= Self.totalLimit else { throw SpeechSynthesisFailure.configuration }
        if pieces.count == 1 { return try await base.synthesize(pieces[0], apiKey: apiKey) }
        let base = self.base
        var audio = [Data?](repeating: nil, count: pieces.count)
        try await withThrowingTaskGroup(of: (Int, Data).self) { group in
            var next = 0
            func start() {
                let index = next, piece = pieces[index]
                group.addTask { (index, try await base.synthesize(piece, apiKey: apiKey)) }
                next += 1
            }
            while next < min(Self.concurrency, pieces.count) { start() }
            while let (index, data) = try await group.next() {
                audio[index] = data
                if next < pieces.count { start() }
            }
        }
        var joined = Data()
        for (index, data) in audio.enumerated() {
            guard let data else { throw SpeechSynthesisFailure.emptyAudio }
            joined.append(index == 0 ? data : Self.droppingID3(data))
            guard joined.count <= Self.maximumBytes else { throw SpeechSynthesisFailure.excessiveAudio }
        }
        return joined
    }

    /// Pieces of at most `pieceLimit` characters, cut after a sentence end
    /// where possible, then after a clause mark, and only then mid-clause.
    static func pieces(_ text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var pieces: [String] = []
        var current = ""
        for unit in sentences(trimmed).flatMap(fit) {
            if current.count + unit.count > pieceLimit {
                pieces.append(current)
                current = ""
            }
            current += unit
        }
        pieces.append(current)
        return pieces.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    /// Foundation's sentence boundaries, which know both 。 and an English
    /// period followed by a space (but not a decimal point or "e.g."). Each
    /// sentence keeps its trailing space so the pieces rejoin to the input.
    private static func sentences(_ text: String) -> [String] {
        var sentences: [String] = []
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: [.bySentences, .substringNotRequired]) { _, _, enclosing, _ in
            sentences.append(String(text[enclosing]))
        }
        return sentences.isEmpty ? [text] : sentences
    }

    /// A sentence too long for one piece, cut at clause marks and then hard.
    private static func fit(_ sentence: String) -> [String] {
        guard sentence.count > pieceLimit else { return [sentence] }
        return units(sentence, at: "，,、：:").flatMap { clause -> [String] in
            guard clause.count > pieceLimit else { return [clause] }
            return stride(from: 0, to: clause.count, by: pieceLimit).map {
                let start = clause.index(clause.startIndex, offsetBy: $0)
                let end = clause.index(start, offsetBy: min(pieceLimit, clause.count - $0))
                return String(clause[start..<end])
            }
        }
    }

    /// Splits after each run of the given marks, keeping the marks.
    private static func units(_ text: String, at marks: String) -> [String] {
        var units: [String] = []
        var current = ""
        var previousWasMark = false
        for character in text {
            let isMark = marks.contains(character)
            if previousWasMark, !isMark {
                units.append(current)
                current = ""
            }
            current.append(character)
            previousWasMark = isMark
        }
        if !current.isEmpty { units.append(current) }
        return units
    }

    /// Both vendors open each MP3 with an ID3v2 tag. Mid-stream tags are
    /// junk to a decoder, so every piece after the first loses its tag.
    static func droppingID3(_ data: Data) -> Data {
        let bytes = [UInt8](data.prefix(10))
        guard bytes.count == 10, bytes[0] == 0x49, bytes[1] == 0x44, bytes[2] == 0x33 else { return data }
        // Syncsafe size: seven bits per byte, plus the 10-byte header and an
        // optional 10-byte footer.
        let size = bytes[6...9].reduce(0) { ($0 << 7) | Int($1 & 0x7F) }
        let length = 10 + size + (bytes[5] & 0x10 != 0 ? 10 : 0)
        guard length < data.count else { return data }
        return data.subdata(in: data.startIndex + length..<data.endIndex)
    }
}
