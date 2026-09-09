import Foundation

/// Voices as each vendor documents them, fetched 2026-09-09:
///
/// - Qwen — help.aliyun.com Model Studio, Qwen-Audio realtime voices and the
///   `qwen-audio-3.0-tts-flash` voice list.
/// - OpenAI — developers.openai.com: the realtime voices, and the longer
///   `/v1/audio/speech` list that adds `fable`, `nova` and `onyx`.
/// - Gemini — ai.google.dev speech generation (the 30-voice table) plus the
///   Live API capabilities guide, which states that native-audio models
///   "support any of the voices available for our Text-to-Speech (TTS)
///   models". Conversation and read-aloud therefore share the set, and the
///   shortlist is the eight the table lists first.
/// - Doubao — docs.volcengine.com/docs/6561/1257544, the 语音合成大模型 2.0
///   table (`_uranus_bigtts` / `ICL_uranus_`, the only voices `seed-tts-2.0`
///   accepts) for read-aloud, and docs/6561/1594356 for the realtime O2.0
///   voices, which are a different set (`_jupiter_bigtts`).
///
/// Voices the vendor tags as platform IP (Volcengine's 抖音同款 / 剪映同款 /
/// 豆包同款 / 番茄小说同款 / 猫箱同款 — 佩奇猪, 四郎, 擎苍, 直率英子 and the
/// rest) are **not written here at all**, rather than collected and filtered:
/// we do not want to ship a licensing question, and Volcengine retires them
/// (a batch went on 2026-06-30). Custom voice ID covers anything absent —
/// cloned voices, newly released ones, and these.
extension VoiceCatalog {
    static let catalog: [Key: [CatalogVoice]] = [
        // MARK: Qwen

        Key(.conversation, .qwen): [
            .init("longanqian", "龙安茜", "Default system voice", language: .chinese, category: "系统音色", core: true),
            .init("longanlingxin", "龙安灵心", "Warm, confiding", language: .chinese, category: "系统音色", core: true),
            .init("longanlingxi", "龙安灵希", "Sweet, cheerful", language: .chinese, category: "系统音色", core: true),
            .init("longanxiaoxin", "龙安小昕", "Friendly, lively", language: .chinese, category: "系统音色", core: true),
            .init("longanlufeng", "龙安鲁风", "Bright, outgoing", language: .chinese, category: "系统音色", core: true),
        ],
        Key(.readAloud, .qwen): [
            .init("longanfengyue", "龙安风悦", "Natural and warm", language: .chinese, category: "社交陪伴", core: true),
            .init("longanyuanfei", "龙安元妃", "Proud, imperial", language: .chinese, category: "社交陪伴", core: true),
            .init("longanlingxi", "龙安灵希", "Sweet, cheerful", language: .chinese, category: "社交陪伴", core: true),
            .init("longanxiaoxin", "龙安小昕", "Friendly, lively", language: .chinese, category: "社交陪伴", core: true),
            .init("longanhuan_v3.6", "龙安欢", "Bright and easy", language: .chinese, category: "社交陪伴", core: true),
            // The reason this ticket exists: an English summary read by a
            // Chinese voice. These three are the vendor's English tier.
            .init("loongmary", "Mary", "Warm British", language: .english, category: "语音助手", core: true),
            .init("loongeva_v3.6", "Eva", "Bright American", language: .english, category: "语音助手", core: true),
            .init("loongjohn", "John", "Steady, friendly American", language: .english, category: "语音助手", core: true),
            .init("longjielidou_v3.6", "龙杰力豆", "Innocent boy", language: .chinese, category: "儿童陪伴"),
            .init("longpaopao_v3.6", "龙泡泡", "Soft and cute", language: .chinese, category: "儿童陪伴"),
            .init("longhuohuo_v3.6", "龙火火", "Mischievous boy", language: .chinese, category: "角色音"),
            .init("longchuanshu_v3.6", "龙川叔", "Sichuan-accented uncle", language: .chinese, category: "角色音"),
        ],

        // MARK: OpenAI — realtime is ten, speech is thirteen.

        Key(.conversation, .openai): openAI([
            "marin", "cedar", "alloy", "ash", "ballad", "coral", "echo", "sage", "shimmer", "verse",
        ], category: "Realtime voices"),
        Key(.readAloud, .openai): openAI([
            "marin", "cedar", "alloy", "ash", "ballad", "coral", "echo",
            "fable", "nova", "onyx", "sage", "shimmer", "verse",
        ], category: "Speech voices"),

        // MARK: Gemini — one documented set, shared by both purposes.

        Key(.conversation, .gemini): geminiVoices,
        Key(.readAloud, .gemini): geminiVoices,

        // MARK: Doubao — realtime O2.0 and TTS 2.0 are different families.

        Key(.conversation, .doubao): [
            .init("zh_female_vv_jupiter_bigtts", "Vivi", "Lively, eager to share", language: .chinese, category: "精品音色", core: true),
            .init("zh_female_xiaohe_jupiter_bigtts", "小何", "Sweet, Taiwanese accent", language: .chinese, category: "精品音色", core: true),
            .init("zh_male_yunzhou_jupiter_bigtts", "云舟", "Crisp and steady", language: .chinese, category: "精品音色", core: true),
            .init("zh_male_xiaotian_jupiter_bigtts", "小天", "Crisp, magnetic", language: .chinese, category: "精品音色", core: true),
            .init("en_male_tim_uranus_bigtts", "Tim", "US English", language: .english, category: "多语种", core: true),
            .init("en_female_dacey_uranus_bigtts", "Dacey", "US English", language: .english, category: "多语种", core: true),
            .init("en_female_stokie_uranus_bigtts", "Stokie", "US English", language: .english, category: "多语种", core: true),
        ],
        Key(.readAloud, .doubao): [
            .init("zh_female_vv_uranus_bigtts", "Vivi 2.0", "Emotional range, ASMR", language: .chinese, category: "通用场景", core: true),
            .init("zh_female_xiaohe_uranus_bigtts", "小何 2.0", "Emotional range, ASMR", language: .chinese, category: "通用场景", core: true),
            .init("zh_male_m191_uranus_bigtts", "云舟 2.0", "Emotional range, ASMR", language: .chinese, category: "通用场景", core: true),
            .init("zh_male_taocheng_uranus_bigtts", "小天 2.0", "Crisp, magnetic", language: .chinese, category: "通用场景", core: true),
            .init("zh_male_liufei_uranus_bigtts", "刘飞 2.0", "Steady narrator", language: .chinese, category: "通用场景", core: true),
            .init("zh_female_qingxinnvsheng_uranus_bigtts", "清新女声 2.0", "Fresh, clear", language: .chinese, category: "通用场景", core: true),
            .init("zh_female_tianmeixiaoyuan_uranus_bigtts", "甜美小源 2.0", "Sweet", language: .chinese, category: "通用场景", core: true),
            .init("zh_female_tianmeitaozi_uranus_bigtts", "甜美桃子 2.0", "Sweet", language: .chinese, category: "通用场景", core: true),
            .init("zh_female_sophie_uranus_bigtts", "魅力苏菲 2.0", "Charming", language: .chinese, category: "通用场景", core: true),
            .init("zh_female_linjianvhai_uranus_bigtts", "邻家女孩 2.0", "Girl next door", language: .chinese, category: "通用场景", core: true),
            .init("zh_female_meilinvyou_uranus_bigtts", "魅力女友 2.0", "Charming", language: .chinese, category: "通用场景", core: true),
            .init("zh_female_qiaopinv_uranus_bigtts", "俏皮女声 2.0", "Playful", language: .chinese, category: "通用场景", core: true),
            .init("zh_female_shuangkuaisisi_uranus_bigtts", "爽快思思 2.0", "Brisk", language: .chinese, category: "通用场景", core: true),
            .init("zh_male_wennuanahu_uranus_bigtts", "温暖阿虎 2.0", "Warm, conversational", language: .chinese, category: "语音闲聊", core: true),
            .init("en_male_tim_uranus_bigtts", "Tim", "US English", language: .english, category: "多语种", core: true),
            .init("en_female_dacey_uranus_bigtts", "Dacey", "US English", language: .english, category: "多语种", core: true),
            .init("en_female_stokie_uranus_bigtts", "Stokie", "US English", language: .english, category: "多语种", core: true),
            .init("ICL_uranus_en_female_charlie_tob", "Charlie 2.0", "US English", language: .english, category: "多语种"),
            .init("ICL_uranus_en_male_ethan_tob", "Ethan 2.0", "Australian English", language: .english, category: "多语种"),
            .init("ICL_uranus_en_male_alastor_tob", "Alastor 2.0", "British English", language: .english, category: "多语种"),
            .init("ICL_uranus_en_male_noah_tob", "Noah 2.0", "US English", language: .english, category: "多语种"),
            .init("zh_female_cancan_uranus_bigtts", "知性灿灿 2.0", "Composed", language: .chinese, category: "角色扮演"),
            .init("zh_female_sajiaoxuemei_uranus_bigtts", "撒娇学妹 2.0", "Coy", language: .chinese, category: "角色扮演"),
            .init("zh_female_kefunvsheng_uranus_bigtts", "暖阳女声 2.0", "Customer service", language: .chinese, category: "客服场景"),
            .init("zh_female_xiaoxue_uranus_bigtts", "儿童绘本 2.0", "Picture books", language: .chinese, category: "有声阅读"),
            .init("zh_female_jitangnv_uranus_bigtts", "鸡汤女 2.0", "Inspirational narration", language: .chinese, category: "视频配音"),
        ],
    ]

    /// OpenAI documents no per-voice language, and recommends `marin`/`cedar`.
    private static func openAI(_ ids: [String], category: String) -> [CatalogVoice] {
        ids.map {
            .init($0, $0, ($0 == "marin" || $0 == "cedar") ? "Recommended by OpenAI" : "",
                  category: category, core: true)
        }
    }

    /// The 30-voice table, multilingual by documentation. The eight the table
    /// lists first are the shortlist; the rest sit behind "show all".
    private static let geminiVoices: [CatalogVoice] = {
        let leading = [("Zephyr", "Bright"), ("Puck", "Upbeat"), ("Charon", "Informative"),
                       ("Kore", "Firm"), ("Fenrir", "Excitable"), ("Leda", "Youthful"),
                       ("Orus", "Firm"), ("Aoede", "Breezy")]
        let rest = [("Callirrhoe", "Easy-going"), ("Autonoe", "Bright"), ("Enceladus", "Breathy"),
                    ("Iapetus", "Clear"), ("Umbriel", "Easy-going"), ("Algieba", "Smooth"),
                    ("Despina", "Smooth"), ("Erinome", "Clear"), ("Algenib", "Gravelly"),
                    ("Rasalgethi", "Informative"), ("Laomedeia", "Upbeat"), ("Achernar", "Soft"),
                    ("Alnilam", "Firm"), ("Schedar", "Even"), ("Gacrux", "Mature"),
                    ("Pulcherrima", "Forward"), ("Achird", "Friendly"), ("Zubenelgenubi", "Casual"),
                    ("Vindemiatrix", "Gentle"), ("Sadachbia", "Lively"), ("Sadaltager", "Knowledgeable"),
                    ("Sulafat", "Warm")]
        return leading.map { CatalogVoice($0.0, $0.0, $0.1, category: "Prebuilt voices", core: true) }
            + rest.map { CatalogVoice($0.0, $0.0, $0.1, category: "More voices") }
    }()
}
