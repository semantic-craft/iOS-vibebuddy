import Foundation

/// What a voice is offered for. The same vendor ships a different set for a
/// realtime conversation than for one-shot speech, so a catalog keyed by
/// provider alone would be wrong.
public enum VoicePurpose: String, Sendable, CaseIterable {
    case conversation, readAloud
}

/// One voice as its vendor documents it.
public struct CatalogVoice: Sendable, Equatable, Identifiable {
    /// The vendor's own voice ID — what goes on the wire.
    public let id: String
    public let name: String
    /// One line of character, as the vendor describes it. May be empty.
    public let trait: String
    /// `nil` when the vendor documents the voice as multilingual.
    public let language: VoiceLanguage?
    /// The vendor's own grouping, shown as the section header.
    public let category: String
    /// In the vendor's own recommended tier — their signal, not our taste.
    public let isCore: Bool

    public init(_ id: String, _ name: String, _ trait: String = "",
                language: VoiceLanguage? = nil, category: String, core: Bool = false) {
        self.id = id
        self.name = name
        self.trait = trait
        self.language = language
        self.category = category
        self.isCore = core
    }

    /// True for the conversation language, and for a multilingual voice always.
    public func speaks(_ language: VoiceLanguage) -> Bool {
        self.language == nil || self.language == language
    }
    /// "Mary · Warm British" — the ID only when it carries no separate name.
    public var label: String {
        let lead = name == id ? name : "\(name) · \(id)"
        return trait.isEmpty ? lead : "\(lead) · \(trait)"
    }
}

/// One of the vendor's own sections of its voice list.
public struct VoiceGroup: Sendable, Equatable, Identifiable {
    public let category: String
    public let voices: [CatalogVoice]
    public var id: String { category }
}

public enum VoiceCatalog {
    /// Past this many, a dropdown stops being a way to choose and the control
    /// becomes a shortlist plus a searchable list of everything.
    public static let tierLimit = 15

    public static func voices(_ purpose: VoicePurpose, _ provider: VoiceProvider) -> [CatalogVoice] {
        catalog[Key(purpose, provider)] ?? []
    }

    public static func isTiered(_ purpose: VoicePurpose, _ provider: VoiceProvider) -> Bool {
        voices(purpose, provider).count > tierLimit
    }

    /// What the dropdown offers. A short catalog lists everything in the
    /// conversation language; a long one lists the vendor's recommended tier.
    /// Neither may come back empty because of the language filter — an empty
    /// dropdown is worse than one in the wrong language.
    public static func shortlist(_ purpose: VoicePurpose, _ provider: VoiceProvider,
                                 language: VoiceLanguage) -> [CatalogVoice] {
        let all = voices(purpose, provider)
        guard !all.isEmpty else { return [] }
        guard all.count > tierLimit else {
            let matched = all.filter { $0.speaks(language) }
            return matched.isEmpty ? all : matched
        }
        let core = all.filter { $0.isCore && $0.speaks(language) }
        return core.isEmpty ? all.filter(\.isCore) : core
    }

    /// The vendor's groups, in the order the vendor documents them.
    public static func grouped(_ voices: [CatalogVoice]) -> [VoiceGroup] {
        var order: [String] = []
        var groups: [String: [CatalogVoice]] = [:]
        for voice in voices {
            if groups[voice.category] == nil { order.append(voice.category) }
            groups[voice.category, default: []].append(voice)
        }
        return order.map { VoiceGroup(category: $0, voices: groups[$0]!) }
    }

    /// Free-text search over everything a row shows, for the full-list panel.
    public static func search(_ query: String, in voices: [CatalogVoice]) -> [CatalogVoice] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return voices }
        return voices.filter {
            "\($0.id) \($0.name) \($0.trait) \($0.category)".lowercased().contains(needle)
        }
    }

    /// The default voice for a purpose: the first the shortlist offers.
    public static func defaultVoice(_ purpose: VoicePurpose, _ provider: VoiceProvider,
                                    language: VoiceLanguage) -> String? {
        shortlist(purpose, provider, language: language).first?.id
    }

    struct Key: Hashable {
        let purpose: VoicePurpose
        let provider: VoiceProvider
        init(_ purpose: VoicePurpose, _ provider: VoiceProvider) {
            self.purpose = purpose
            self.provider = provider
        }
    }
}
