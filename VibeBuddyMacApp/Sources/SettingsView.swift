import SwiftUI
import AppKit
import VibeBuddyKit
import VibeBuddyMacCore

/// The Cmd+, Settings window: a classic top-tab Preferences layout (deliberately
/// not NavigationSplitView). Consolidates preferences that used to live in the
/// menu-bar popover, plus the configurable Open-Dashboard global hotkey.
struct SettingsView: View {
    @ObservedObject var model: MenuBarModel

    var body: some View {
        TabView {
            GeneralSettings(model: model)
                .tabItem { Label("General", systemImage: "gearshape") }
            GlanceSettings(model: model)
                .tabItem { Label("Glance", systemImage: "menubar.rectangle") }
            DeviceSettings(model: model)
                .tabItem { Label("Devices", systemImage: "iphone.gen3") }
            NotificationSettings()
                .tabItem { Label("Notifications", systemImage: "bell") }
            VoiceSettingsTab()
                .tabItem { Label("Voice", systemImage: "waveform") }
        }
        .frame(width: 500, height: 360)
        .onDisappear { AppActivationPolicy.leave() }
    }
}

private struct GeneralSettings: View {
    @ObservedObject var model: MenuBarModel
    @AppStorage("showMenuBarIcon") private var showMenuBarIcon = true
    @State private var showHideIconNote = false

    var body: some View {
        Form {
            Toggle("Launch at Login", isOn: Binding(
                get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))

            Toggle("Show icon in menu bar", isOn: Binding(
                get: { showMenuBarIcon },
                set: { on in showMenuBarIcon = on; if !on { showHideIconNote = true } }))
            if showHideIconNote {
                Text("Hidden. You can still open the Dashboard with \(model.openDashboardHotkey.displayString) — it has a Settings button.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider().padding(.vertical, 4)

            LabeledContent("Open Dashboard") {
                HotkeyRecorderView(current: model.openDashboardHotkey, onRecord: model.setHotkey)
            }
            Text("A global shortcut that opens the Dashboard from anywhere. Hyper (⌃⌥⇧⌘) combos recommended.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            LabeledContent("Toggle Glance") {
                HotkeyRecorderView(current: model.toggleGlanceHotkey, onRecord: model.setGlanceHotkey)
            }
            Text("Show/hide the floating glance from the keyboard — handy on a notchless screen where it would otherwise sit on top of your work.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider().padding(.vertical, 4)

            Picker("Clean up idle sessions after", selection: Binding(
                get: { model.idleTimeoutHours }, set: { model.setIdleTimeout($0) })) {
                Text("30 min").tag(0.5)
                Text("1 hour").tag(1.0)
                Text("2 hours").tag(2.0)
                Text("4 hours").tag(4.0)
                Text("8 hours").tag(8.0)
                Text("24 hours").tag(24.0)
                Text("Never").tag(0.0)
            }
        }
        .formStyle(.grouped)
    }
}

private struct GlanceSettings: View {
    @ObservedObject var model: MenuBarModel
    var body: some View {
        Form {
            Toggle("Show glance", isOn: Binding(
                get: { model.showGlance }, set: { model.setShowGlance($0) }))
            Picker("Size", selection: Binding(
                get: { model.glanceScale }, set: { model.setGlanceScale($0) })) {
                Text("Small").tag(CGFloat(0.8))
                Text("Medium").tag(CGFloat(1.0))
                Text("Large").tag(CGFloat(1.2))
            }
            .pickerStyle(.segmented)
            .disabled(!model.showGlance)
        }
        .formStyle(.grouped)
    }
}

private struct NotificationSettings: View {
    @AppStorage("notifyOnNeedsResponse") private var notify = true
    @AppStorage("playNotificationSound") private var sound = true
    @AppStorage("quietMode") private var quiet = false
    @AppStorage("sessionBudgetUSD") private var budgetUSD = 0.0
    @State private var quietHours = NotificationSettings.loadQuietHours()

    var body: some View {
        Form {
            Section {
                Toggle("Show notifications", isOn: $notify)
                Toggle("Play sound", isOn: $sound).disabled(!notify)
            } footer: {
                Text("A short, built-in cue for each state change — needs you, approval, finished, or stuck. Only boundaries ring; ongoing work stays silent.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Quiet mode (approvals only)", isOn: $quiet).disabled(!notify)
            } footer: {
                Text("For night or focus time: only security approvals make a sound. Everything else stays silent.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Picker("Budget alert per session", selection: $budgetUSD) {
                    Text("Off").tag(0.0)
                    Text("$1").tag(1.0)
                    Text("$2").tag(2.0)
                    Text("$5").tag(5.0)
                    Text("$10").tag(10.0)
                    Text("$20").tag(20.0)
                }.disabled(!notify)
            } footer: {
                Text("A gentle heads-up when a session's estimated spend crosses this amount. Cost is a rough estimate from token usage.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Quiet hours", isOn: $quietHours.enabled).disabled(!notify)
                if quietHours.enabled {
                    Picker("From", selection: $quietHours.startHour) { hourTags }
                    Picker("To", selection: $quietHours.endHour) { hourTags }
                }
            } footer: {
                Text("Automatically enter Quiet mode during this nightly window.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: quietHours) { _, q in NotificationSettings.saveQuietHours(q) }
    }

    private var hourTags: some View {
        ForEach(0..<24, id: \.self) { h in Text(String(format: "%02d:00", h)).tag(h) }
    }

    private static func loadQuietHours() -> QuietHours {
        guard let data = UserDefaults.standard.data(forKey: "quietHours"),
              let q = try? JSONDecoder().decode(QuietHours.self, from: data) else { return QuietHours() }
        return q
    }

    private static func saveQuietHours(_ q: QuietHours) {
        if let data = try? JSONEncoder().encode(q) { UserDefaults.standard.set(data, forKey: "quietHours") }
    }
}

private struct VoiceSettingsTab: View {
    @AppStorage(VoiceSettings.enabledKey) private var enabled = false
    @AppStorage(VoiceSettings.regionIntlKey) private var intl = false
    @State private var apiKey = ""

    var body: some View {
        Form {
            Section {
                Toggle("Voice companion", isOn: $enabled)
                SecureField("Qwen (DashScope) API Key", text: $apiKey)
                    .disabled(!enabled)
                Toggle("Use international site (dashscope-intl)", isOn: $intl).disabled(!enabled)
            } footer: {
                Text("Tap the buddy to talk — it knows your sessions and can approve / answer for you. Speech recognition and reading aloud run on-device; only the conversation uses your own Qwen key (kept in the Keychain, never uploaded or committed).")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { apiKey = VoiceSettings.apiKey ?? "" }
        .onChange(of: apiKey) { _, v in KeychainStore.set(v, for: VoiceSettings.apiKeyKeychain) }
    }
}

private struct DeviceSettings: View {
    @ObservedObject var model: MenuBarModel

    var body: some View {
        Form {
            Section {
                LabeledContent("This Mac") {
                    Text(model.macDisplayName)
                        .font(.body.weight(.medium))
                }
                LabeledContent("Pairing address") {
                    Text(model.pairingAddress)
                        .font(.body.monospaced())
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                if let phone = model.pairedPhone {
                    LabeledContent("Paired phone") {
                        Text(phone.name)
                            .font(.body.weight(.medium))
                    }
                    if !phone.subtitle.isEmpty {
                        LabeledContent("Device") {
                            Text(phone.subtitle)
                                .foregroundStyle(.secondary)
                        }
                    }
                    LabeledContent("Last seen") {
                        Text(phone.lastSeen, style: .relative)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("Push") {
                        Label(phone.pushRegistered ? "Registered" : "Pending",
                              systemImage: phone.pushRegistered ? "bell.badge.fill" : "bell.slash")
                            .foregroundStyle(phone.pushRegistered ? .green : .secondary)
                    }
                    Button(role: .destructive) {
                        model.forgetPairedPhone()
                    } label: {
                        Label("Forget phone", systemImage: "iphone.slash")
                    }
                } else {
                    Label("No phone paired", systemImage: "iphone.slash")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// Records a global shortcut. While recording, a local event monitor swallows
/// the next key combo (the Settings window has focus, so a local monitor is
/// enough — no Accessibility permission). Bare keys (no modifier) are rejected
/// so the shortcut can't shadow ordinary typing; Esc cancels.
struct HotkeyRecorderView: View {
    let current: Hotkey
    let onRecord: (Hotkey) -> Void
    @State private var recording = false
    @State private var monitor: Any?
    @State private var hint = false

    var body: some View {
        HStack(spacing: 8) {
            Text(recording ? "Press a combo…" : current.displayString)
                .font(.system(.body, design: .rounded).weight(.medium))
                .frame(minWidth: 84)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlColor)))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .stroke(recording ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: 1))
            Button(recording ? "Cancel" : "Record") { recording ? stop() : start() }
            if hint {
                Text("needs a modifier").font(.caption2).foregroundStyle(.red)
            }
        }
        .onDisappear { stop() }
    }

    private func start() {
        hint = false
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            handle(event)
            return nil   // swallow the key while recording
        }
    }

    private func stop() {
        recording = false
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }

    private func handle(_ event: NSEvent) {
        if event.keyCode == 53 { stop(); return }   // Escape cancels
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let hk = Hotkey(keyCode: UInt32(event.keyCode),
                        cocoaModifiers: mods.rawValue,
                        displayKey: Self.keyLabel(for: event))
        guard hk.hasModifier else { hint = true; return }   // keep recording, show hint
        onRecord(hk)
        stop()
    }

    private static func keyLabel(for event: NSEvent) -> String {
        switch event.keyCode {
        case 49:  return "Space"
        case 36:  return "Return"
        case 48:  return "Tab"
        case 51:  return "⌫"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        default:
            let c = event.charactersIgnoringModifiers ?? ""
            return c.isEmpty ? "Key\(event.keyCode)" : c.uppercased()
        }
    }
}
