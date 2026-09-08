import SwiftUI

/// NSWindow is retained after close, so onDisappear alone cannot own cleanup.
struct SettingsTestLifecycle: ViewModifier {
    let tests: SettingsTestCoordinator

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { notification in
                guard let window = notification.object as? NSWindow,
                      window.identifier == NSUserInterfaceItemIdentifier("com.vibebuddy.settings") else { return }
                tests.invalidate()
            }
            .onDisappear { tests.invalidate() }
    }
}
