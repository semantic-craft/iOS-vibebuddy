import Foundation

/// A persona for read-aloud: serious, coquettish or sultry.
///
/// Listening tests (2026-09-26) settled what a persona has to be. An
/// instruction alone — Volcengine's `context_texts`, Alibaba's `instruction` —
/// barely moves a neutral voice reading a neutral report: both models follow
/// the *meaning* of the text far more than the note about delivery. What the
/// owner could hear was three levers pulled together:
///
/// 1. a voice that already carries the persona (`voice(for:language:)`),
/// 2. a concrete, multi-dimensional delivery note (`persona(_:)`), and
/// 3. wording written in the persona (`wording(_:)`), which the speech summary
///    prompt applies before any audio exists.
///
/// So a style owns all three. `.standard` is the pre-existing behaviour and
/// pulls none of them: the request is exactly what it was before styles.
public enum VoiceStyle: String, Sendable, CaseIterable, Equatable, Hashable {
    case standard
    case serious
    case coquettish
    case sultry

    /// English source text; the app's string tables translate it.
    public var display: String {
        switch self {
        case .standard: NSLocalizedString("Standard", comment: "Read-aloud voice style")
        case .serious: NSLocalizedString("Serious", comment: "Read-aloud voice style")
        case .coquettish: NSLocalizedString("Coquettish", comment: "Read-aloud voice style")
        case .sultry: NSLocalizedString("Sultry", comment: "Read-aloud voice style")
        }
    }

    /// The delivery note, in the language being spoken — a note in another
    /// language reads to the vendor as a language switch. `nil` for `.standard`.
    public func persona(_ language: VoiceLanguage) -> VoicePersona? {
        switch (self, language) {
        case (.standard, _):
            return nil
        case (.serious, .chinese):
            return .init(tone: "严肃冷静、公事公办的新闻播报",
                         speaker: "严肃端庄的新闻播音员，语气沉稳克制，吐字清晰，不带笑意。", language)
        case (.serious, .english):
            return .init(tone: "serious, calm, matter-of-fact newsreader",
                         speaker: "A serious news anchor: steady, restrained, crisp diction, no smile in the voice.", language)
        case (.coquettish, .chinese):
            return .init(tone: "撒娇卖萌、嗲嗲的夹子音",
                         speaker: "撒娇卖萌的年轻女生，声音甜嗲，语调上扬，尾音拖长，像在邀功求夸奖。", language)
        case (.coquettish, .english):
            return .init(tone: "cutesy, pouty, sing-song",
                         speaker: "A cutesy young woman, sugary and pouty, rising pitch, drawn-out endings.", language)
        case (.sultry, .chinese):
            return .init(tone: "慵懒暧昧、压低声音、气声很重、带点撩人",
                         speaker: "慵懒性感的成熟女性，压低嗓音，气声很重，语速缓慢，像在耳边低语。", language)
        case (.sultry, .english):
            return .init(tone: "lazy, husky, breathy and flirtatious",
                         speaker: "A sultry woman, low and breathy, slow and lazy, as if whispering close by.", language)
        }
    }

    /// A voice that already carries the persona, and the model it needs. It
    /// replaces the voice picked in Settings while the style is on — the
    /// picked voice cannot carry a persona the tests showed an instruction
    /// cannot add. `nil` keeps the picked voice: `.standard`, a vendor with no
    /// such voice, a language the listed voice does not speak, or Qwen's
    /// Singapore region, where these voices were never verified.
    public func voice(for provider: VoiceProvider, language: VoiceLanguage,
                      qwenUseIntl: Bool = false) -> StyledVoice? {
        // The persona voices were verified on the Beijing endpoint only.
        guard language == .chinese, !(provider == .qwen && qwenUseIntl) else { return nil }
        switch (self, provider) {
        case (.serious, .doubao): return .init(model: DoubaoSpeechSynthesizer.defaultModel, voice: "zh_female_zhixingnv_uranus_bigtts")
        case (.coquettish, .doubao): return .init(model: DoubaoSpeechSynthesizer.defaultModel, voice: "zh_female_sajiaoxuemei_uranus_bigtts")
        case (.sultry, .doubao): return .init(model: DoubaoSpeechSynthesizer.defaultModel, voice: "zh_female_meilinvyou_uranus_bigtts")
        case (.serious, .qwen): return .init(model: QwenSpeechSynthesizer.styledModel, voice: "xiaoxingzhi_v3.1")
        case (.coquettish, .qwen): return .init(model: QwenSpeechSynthesizer.styledModel, voice: "anyuqing_v3.1")
        case (.sultry, .qwen): return .init(model: QwenSpeechSynthesizer.styledModel, voice: "anruorou_v3.1")
        default: return nil
        }
    }

    /// How the spoken summary is worded, for the summary prompt. The facts and
    /// the length rules stay the prompt's; this only changes the voice of the
    /// prose, which is the lever the TTS models actually follow.
    public func wording(_ language: VoiceLanguage) -> String? {
        switch (self, language) {
        case (.standard, _):
            return nil
        case (.serious, .chinese):
            return "播报人设：严肃的新闻播音员。用正式、克制的书面口吻，句子完整利落，不用语气词、感叹号和波浪号。"
        case (.serious, .english):
            return "Persona: a serious newsreader. Formal, restrained sentences; no interjections, exclamation marks or tildes."
        case (.coquettish, .chinese):
            return "播报人设：爱撒娇的小女生在向对方邀功。可以自称“人家”，句尾多用“啦、哦、嘛、呢”和“～”，偶尔用“好不好嘛”“快夸夸我”这类撒娇的话；这些只改语气，不增删事实。说失败原因的那一句和最后一句不撒娇、不加语气词，最后一句仍是记录里等你做的事或最终结果。"
        case (.coquettish, .english):
            return "Persona: a cutesy, pouty girl showing off her work. Playful sing-song phrasing, soft interjections like \"hehe\" and \"pretty please\"; tone only — never add or drop facts. The sentence giving a failure's cause and the final sentence stay plain, and the final sentence is still what the record waits on you for, or the end result."
        case (.sultry, .chinese):
            return "播报人设：慵懒暧昧的成熟女性在耳边低语。多用短句和“嗯……”“呢”，用省略号制造停顿，语气放慢、带点撩人；这些只改语气，不增删事实。说失败原因的那一句和最后一句不加语气词，最后一句仍是记录里等你做的事或最终结果。"
        case (.sultry, .english):
            return "Persona: a lazy, flirtatious woman murmuring close by. Short sentences, soft \"mm…\" and ellipsis pauses; tone only — never add or drop facts. The sentence giving a failure's cause and the final sentence stay plain, and the final sentence is still what the record waits on you for, or the end result."
        }
    }

    /// A preview line already worded in the persona, because a neutral line
    /// cannot demonstrate one — the same reason summaries are reworded.
    /// `nil` for `.standard`, whose callers keep their own line.
    public func previewLine(_ language: VoiceLanguage) -> String? {
        switch (self, language) {
        case (.standard, _): return nil
        case (.serious, .chinese): return "任务已经完成，测试全部通过。下一步是在手机上验收。"
        case (.serious, .english): return "The task is complete and all checks passed. Next, confirm it on your phone."
        case (.coquettish, .chinese): return "人家把任务做完啦～测试全都通过了哦。就等你在手机上看一眼嘛，快夸夸我！"
        case (.coquettish, .english): return "Hehe, I finished the task, and every check passed! Just take a peek on your phone, pretty please?"
        case (.sultry, .chinese): return "嗯……任务，我已经做完了。测试也都通过了呢。接下来……就等你，在手机上慢慢看。"
        case (.sultry, .english): return "Mm… the task is done. Every check passed. Now… it's just waiting for you, on your phone."
        }
    }

    /// A stored value this build cannot parse is `.standard` — including the
    /// retired `girlNextDoor` / `fieryGirl` tiers — because inventing a
    /// persona is worse than reading plainly.
    public init(stored: String?) {
        self = VoiceStyle(rawValue: (stored ?? "").trimmingCharacters(in: .whitespacesAndNewlines)) ?? .standard
    }
}

/// One persona's delivery note, in the two shapes the vendors document.
public struct VoicePersona: Sendable, Equatable {
    /// The tone, as a noun phrase ("撒娇卖萌、嗲嗲的夹子音").
    public let tone: String
    /// A description of the speaker, for a vendor whose instruction describes
    /// who is talking ("年轻活泼的女性声音，语速较快…"). Alibaba caps
    /// `instruction` at 100 characters with each Han character counting two,
    /// so every Chinese one stays under 50 characters.
    public let speaker: String
    let language: VoiceLanguage

    init(tone: String, speaker: String, _ language: VoiceLanguage) {
        self.tone = tone
        self.speaker = speaker
        self.language = language
    }

    /// A stage direction before the line, for a vendor whose examples frame
    /// the instruction as one ("用最悲伤的语气演绎下面这句话：").
    public var cue: String {
        switch language {
        case .chinese: "用\(tone)的语气演绎下面这句话："
        case .english: "Perform the next lines in a \(tone) voice:"
        }
    }
}

/// The voice a style speaks with, and the model that voice needs — pinned,
/// because a hand-set model (a cloning resource, TTS 1.0) would reject it.
public struct StyledVoice: Sendable, Equatable {
    public let model: String
    public let voice: String
}
