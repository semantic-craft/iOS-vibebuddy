import SwiftUI
import VibeBuddyKit

/// Choosing a voice from the built-in catalog. Short catalogs are a plain
/// dropdown; long ones show the vendor's recommended tier with a searchable
/// panel behind it. Custom voice ID is always the last way out, for cloned and
/// newly released voices the catalog cannot know about.
struct VoicePicker<Trailing: View>: View {
    /// Names this row's voice for VoiceOver, since two rows both have one.
    let label: LocalizedStringKey
    let purpose: VoicePurpose
    let provider: VoiceProvider
    let language: VoiceLanguage
    /// What the runtime uses when nothing is stored. The picker must show the
    /// same voice the provider would actually speak with, not its own guess.
    let fallback: String
    @Binding var voiceID: String
    @ViewBuilder let trailing: Trailing

    @State private var custom = false
    @State private var showingAll = false
    @State private var query = ""

    /// Picked from the dropdown, never a voice ID.
    private static var customTag: String { "\u{1}custom" }

    private var all: [CatalogVoice] { VoiceCatalog.voices(purpose, provider) }
    private var shortlist: [CatalogVoice] { VoiceCatalog.shortlist(purpose, provider, language: language) }
    /// A blank stored value shows what the runtime would use, falling back to
    /// the catalog's first when a provider has no default of its own. Nothing
    /// is written until the user picks.
    private var effectiveID: String {
        if !voiceID.isEmpty { return voiceID }
        if !fallback.isEmpty { return fallback }
        return VoiceCatalog.defaultVoice(purpose, provider, language: language) ?? ""
    }
    private var selection: Binding<String> {
        Binding(get: { effectiveID }, set: { picked in
            if picked == Self.customTag { custom = true } else { voiceID = picked }
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if custom {
                HStack(spacing: 6) {
                    TextField("Voice ID", text: $voiceID, prompt: Text("voice ID from the provider’s docs"))
                        .labelsHidden().textFieldStyle(.roundedBorder)
                        .font(.caption.monospaced()).autocorrectionDisabled()
                        .accessibilityLabel(label)
                        .accessibilityIdentifier("customVoiceID")
                    trailing
                }
                // The list keeps a row for an off-catalog value, so returning to
                // it must not discard the ID the user just typed.
                Button("Back to the list") { custom = false }
                .buttonStyle(.link).font(.caption)
            } else {
                HStack(spacing: 6) {
                    Picker(label, selection: selection) {
                        ForEach(VoiceCatalog.grouped(shortlist)) { group in
                            Section(group.category) {
                                ForEach(group.voices) { Text(verbatim: $0.label).tag($0.id) }
                            }
                        }
                        // A voice chosen from the full list, or kept from an
                        // earlier language, still needs a tag of its own.
                        if !effectiveID.isEmpty, !shortlist.contains(where: { $0.id == effectiveID }) {
                            Text(verbatim: all.first { $0.id == effectiveID }?.label ?? effectiveID)
                                .tag(effectiveID)
                        }
                        Divider()
                        Text("Custom voice ID…").tag(Self.customTag)
                    }
                    .labelsHidden().accessibilityLabel(label)
                    trailing
                }
                if VoiceCatalog.isTiered(purpose, provider) {
                    Button("Show all \(all.count) voices…") { query = ""; showingAll = true }
                        .buttonStyle(.link).font(.caption)
                        .popover(isPresented: $showingAll, arrowEdge: .bottom) { fullList }
                } else {
                    Text("\(shortlist.count) voices from \(provider.display)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var fullList: some View {
        let matches = VoiceCatalog.search(query, in: all)
        return VStack(alignment: .leading, spacing: 8) {
            TextField("Search", text: $query, prompt: Text("Search \(all.count) voices…"))
                .textFieldStyle(.roundedBorder).labelsHidden()
                .accessibilityLabel("Search voices")
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2, pinnedViews: .sectionHeaders) {
                    if matches.isEmpty {
                        Text("No match").font(.caption).foregroundStyle(.secondary).padding(.vertical, 6)
                    }
                    ForEach(VoiceCatalog.grouped(matches)) { group in
                        Section {
                            ForEach(group.voices) { voice in
                                Button {
                                    voiceID = voice.id
                                    showingAll = false
                                } label: {
                                    HStack(spacing: 6) {
                                        Text(verbatim: voice.name)
                                        Text(verbatim: voice.trait.isEmpty ? voice.id : voice.trait)
                                            .foregroundStyle(.secondary)
                                        Spacer(minLength: 0)
                                        if voice.id == effectiveID {
                                            Image(systemName: "checkmark").foregroundStyle(.tint)
                                        }
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        } header: {
                            HStack {
                                Text(verbatim: group.category)
                                Spacer(minLength: 0)
                                Text(verbatim: "\(group.voices.count)")
                            }
                            .font(.caption.bold()).foregroundStyle(.secondary)
                            .padding(.vertical, 2).background(.background)
                        }
                    }
                }
                .font(.callout)
            }
            .frame(width: 320, height: 260)
        }
        .padding(12)
    }
}

extension VoicePicker where Trailing == EmptyView {
    init(label: LocalizedStringKey, purpose: VoicePurpose, provider: VoiceProvider,
         language: VoiceLanguage, fallback: String, voiceID: Binding<String>) {
        self.init(label: label, purpose: purpose, provider: provider, language: language,
                  fallback: fallback, voiceID: voiceID) { EmptyView() }
    }
}
