import ClockKit

/// Empty ClockKit data source, named by `CLKComplicationPrincipalClass` in the
/// Watch app's Info.plist. It publishes no ClockKit complications: every real
/// complication lives in the WidgetKit extension. It exists because iOS's Watch
/// app adds a third-party app to its complication configuration UI only when the
/// watch reports a ClockKit principal class, and a single-target watch app never
/// reports one otherwise, so the quota configuration page showed a placeholder
/// instead of the app icon.
final class ComplicationController: NSObject, CLKComplicationDataSource {
    func getComplicationDescriptors(handler: @escaping ([CLKComplicationDescriptor]) -> Void) {
        handler([])
    }

    func getCurrentTimelineEntry(for complication: CLKComplication,
                                 withHandler handler: @escaping (CLKComplicationTimelineEntry?) -> Void) {
        handler(nil)
    }
}
