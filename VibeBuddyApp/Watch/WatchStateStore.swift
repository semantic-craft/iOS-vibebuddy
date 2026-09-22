import Foundation
import VibeBuddyKit
import WatchConnectivity
import WidgetKit

/// Everything the Watch knows, and where it came from.
///
/// The Watch has exactly one source: the paired iPhone, over WatchConnectivity.
/// It opens no LAN socket, discovers no Mac, holds no bearer token, and calls no
/// daemon route — losing the Watch grants nobody access to anything.
///
/// Demo Mode is the one exception, and it is local: a deterministic scenario
/// rendered from a frozen clock so a screenshot of a given launch input always
/// reproduces.
@MainActor
final class WatchStateStore: NSObject, ObservableObject {
    @Published private(set) var state: WatchDashboardState?
    @Published var taskLink: WatchTaskLink? {
        didSet {
            if oldValue != nil, oldValue != taskLink { withdrawBannerAction() }
            cancelPendingNavigation()
        }
    }
    @Published var quotaSelection: WatchQuotaSelection? {
        didSet { cancelPendingNavigation() }
    }
    @Published private(set) var completionQueue = WatchCompletionQueue()
    private var completionAttempt: WatchCompletionRequest?
    private var retryTask: Task<Void, Never>?
    @Published private(set) var isRefreshingTask = false
    @Published private(set) var taskRefreshFailed = false
    private var refreshAttempt: WatchRefreshRequest?
    private var refreshTimeout: Task<Void, Never>?
    @Published private(set) var isOpeningActivity = false
    @Published var activityOpenError: String?
    private var diagnosticDelivery: Task<Void, Never>?
    private var resolvedActivityLink: WatchTaskLink?
    private var activityRequest: WatchActivityOpenRequest?
    private var activityTimeout: Task<Void, Never>?
    private var actionReplyTimeout: Task<Void, Never>?
    private var retryAfter: [WatchTaskLink: Date] = [:]
    private var retryCount: [WatchTaskLink: Int] = [:]
    /// The one action in flight — approve, deny, or stop — and everything the
    /// wrist may claim about it. When an attempt comes to rest the wrist taps
    /// once for taken and twice for anything else, so a decision made from a
    /// banner is felt without reading the card (ADR-0033).
    @Published private(set) var pendingAction = WatchSessionActionState() {
        didSet {
            feelActionOutcome(from: oldValue, to: pendingAction)
            // The slot freeing is what makes "another action is still on its
            // way" stop being true, and no snapshot need follow it — a failed
            // reply is the end of the story. So the phase change is the event,
            // not the next state.
            if oldValue.isBusy != pendingAction.isBusy { refreshFallback() }
        }
    }
    /// A banner button's decision, held until the relayed state can place it
    /// and the link can carry it. Cleared the moment it is sent, refused, or
    /// times out.
    private var bannerAction: WatchBannerAction?
    private var bannerActionTimeout: Task<Void, Never>?
    /// Whether any state has arrived over the link this launch. Until one has,
    /// the state on screen is the cache on disk, whose approval and question
    /// ids are stripped — it can draw a card but cannot answer a question about
    /// what is still waiting.
    private var hasRelayedState = false
    /// What the sentence on the card is about, so it can be taken down the
    /// moment a state arrives that contradicts it.
    private var bannerActionFallbackRoute: WatchNotificationResponseRoute?
    /// The question a reply's sentence is about, when it had been bound to one.
    /// Without it, "this is no longer waiting on you" — said *because* the
    /// question moved on — would be taken down by the very question that
    /// replaced it, leaving the dictation unexplained.
    private var bannerActionFallbackPendingID: String?
    /// Why the last banner action was not sent, shown on the card the tap
    /// opened. Nil once it was sent, or once the card is dismissed.
    @Published var bannerActionFallback: WatchBannerActionFallback?
    /// Whether the iPhone is in range right now. It is the only way the Watch
    /// can tell "the phone stopped relaying" from "the phone is gone", and it is
    /// read live rather than relayed — a reachability flag inside a payload
    /// would be describing the moment the payload was sent. A decision is a live
    /// request and needs the phone awake, so it also gates the buttons.
    @Published private(set) var isPhoneReachable = false

    /// Sample data driven entirely by launch inputs; no relay is opened.
    let isDemo: Bool
    /// Demo Mode's frozen clock. Live state ages against the real one.
    let launchedAt: Date
    let initialPage: WatchPage
    /// Demo Mode only: an answer to open the confirmation page on at launch.
    ///
    /// That page is normally two taps deep, and it is the page this whole flow
    /// turns on — where the answer is read back and the target named. A
    /// simulator has no wrist, so without this input the one screen most worth
    /// reviewing is the one nobody can look at.
    ///
    /// Read through `consumeDemoAnswerDraft()`, which hands it over once for
    /// the whole app: the task detail is a sheet *over* the home screen, so two
    /// cards can be on screen at the same moment and only one of them may
    /// present a page.
    private var demoAnswerDraft: String?

    private var inbox = WatchStateInbox()
    private var session: WCSession?
    /// Which state boundaries have already been felt. Every arriving state is
    /// recorded here whether or not it is played, so a transition the wrist
    /// slept through is history by the time the app comes forward.
    private var haptics = WatchHapticTransitions()
    /// Only a wrist that is actually looking gets tapped. The iPhone's mirrored
    /// notification owns the other moment, and its short-look haptic belongs to
    /// the system.
    ///
    /// It starts false and is only ever raised by the window scene reporting
    /// itself active. The process is started for reasons that are not someone
    /// looking at the app — rendering a long look, taking a WatchConnectivity
    /// delivery — and a scene-phase observer cannot correct an optimistic guess
    /// because it never fires for a scene that does not appear. False also
    /// makes the first live state after a cold launch a baseline rather than
    /// news: whatever it says, the phone announced it hours ago.
    private var isForeground = false

    init(environment: [String: String] = ProcessInfo.processInfo.environment,
         now: Date = Date()) {
        launchedAt = now
        isDemo = environment["VIBEBUDDY_DEMO"] == "1"
        initialPage = environment["VIBEBUDDY_WATCH_PAGE"]
            .flatMap(WatchPage.init(rawValue:)) ?? .home
        demoAnswerDraft = isDemo
            ? environment["VIBEBUDDY_WATCH_ANSWER"].flatMap { $0.isEmpty ? nil : $0 }
            : nil
        super.init()

        if isDemo {
            let scenario = environment["VIBEBUDDY_WATCH_SCENARIO"]
                .flatMap(WatchDemoScenario.init(rawValue:)) ?? .normal
            state = scenario.state(now: now)
            isPhoneReachable = scenario.phoneReachable
            // Task detail is normally reached from a complication, which reads
            // a cache Demo Mode deliberately never writes. This is the launch
            // input that opens it anyway, so the screens that only exist there
            // — Stop, and its confirmation — are reviewable in a simulator.
            if let sessionID = environment["VIBEBUDDY_WATCH_TASK"], !sessionID.isEmpty {
                taskLink = WatchTaskLink(sourceID: WatchDemoScenario.sourceID,
                                         pairingEpoch: WatchDemoScenario.pairingEpoch,
                                         sessionID: sessionID, completionID: state?.task(sessionID)?.completionID)
            }
            if let sample = state { seedHaptics(sample) }
            if environment["VIBEBUDDY_WATCH_HAPTIC_DEMO"] == "1" {
                rehearseHapticTransition()
            }
        } else {
            // A cold launch shows the last state the iPhone managed to deliver.
            // Its age is recomputed from the current clock, never restored as a
            // verdict, so old numbers cannot masquerade as live ones.
            if let saved = WatchComplicationStore.loadState() {
                completionQueue = saved.queue
                inbox = WatchStateInbox(state: saved.state)
                state = saved.state
                seedHaptics(saved.state)
                completionQueue.reconcile(with: saved.state)
            }
            WatchNavigationDiagnostics.shared.onChange = { [weak self] in self?.scheduleDiagnostics() }
            WatchNavigationDiagnostics.shared.record("store.ready")
            activate()
            // A tapped notification names a session; open it here, or as soon
            // as a state that knows it arrives. A tapped *button* also names
            // what to do about it.
            WatchNotificationRouter.shared.attach { [weak self] route in
                self?.perform(route)
            }
            retryTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(5))
                    guard !Task.isCancelled else { return }
                    self?.flushCompletions()
                }
            }
        }
    }

    deinit {
        refreshTimeout?.cancel()
        diagnosticDelivery?.cancel()
        retryTask?.cancel()
        actionReplyTimeout?.cancel()
        activityTimeout?.cancel()
        bannerActionTimeout?.cancel()
    }

    // MARK: - Notification routes

    /// Act on a tapped notification: open its session, and when a button was
    /// tapped, carry that decision through the same path the card's buttons
    /// use. The card opens first in every case, so whatever happens next is
    /// happening on a screen the person is looking at.
    func perform(_ route: WatchNotificationResponseRoute) {
        guard let sessionID = route.sessionID else { return }
        bannerActionFallback = nil
        bannerActionFallbackRoute = nil
        bannerActionFallbackPendingID = nil
        openSession(sessionID)
        guard route.isAction else { return }
        bannerActionTimeout?.cancel()
        // No baseline yet: whatever is on screen at the tap is the cache, or a
        // context taken while the relay was down, and a mark read off either
        // makes the first honest snapshot look like proof — a live snapshot is
        // legitimately newer than the cache and legitimately may not carry an
        // approval still in flight. The first evidence state sets it
        // (`noteInstalled`, past the guard below).
        bannerAction = WatchBannerAction(route: route)
        WatchNavigationDiagnostics.shared.record("banner.action-held")
        // The relayed state and the phone's reachability arrive moments after a
        // cold launch; wait for them, but not so long that the tap becomes a
        // decision about a request the person has stopped looking at.
        bannerActionTimeout = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(WatchBannerAction.patience))
            guard !Task.isCancelled else { return }
            self?.settleBannerAction(expired: true)
        }
        settleBannerAction(expired: false)
    }

    /// Try to send the held banner action against what the wrist knows now.
    /// Runs on every new state and every reachability change until it either
    /// goes out or is given up with a reason on the card.
    private func settleBannerAction(expired: Bool) {
        guard let held = bannerAction else { return }
        func giveUp(_ reason: WatchBannerActionFallback) {
            let bound = bannerAction?.boundPendingID
            bannerAction = nil
            bannerActionTimeout?.cancel()
            bannerActionFallback = reason
            bannerActionFallbackRoute = held.route
            bannerActionFallbackPendingID = bound
            WatchNavigationDiagnostics.shared.record("banner.action-fallback.\(reason.rawValue)")
            WatchHapticPlayer.shared.play(WatchHaptics.beats(for: .error), reason: "banner action \(reason.rawValue)")
        }
        guard let state, state.sourceID != nil, state.pairingEpoch != nil else {
            if expired { giveUp(.noState) }
            return
        }
        // Nothing is concluded from a state that is not evidence.
        //
        // Two kinds reach here and neither can answer a question about what the
        // Mac is waiting for. The cache on disk has every approval and question
        // id stripped out of it (`WatchStoredState` keeps no actionable card),
        // so its alerts can never match the tap — a decision read from it looks
        // resolved and a reply looks unanswerable, both false. And a payload
        // taken while the relay is down carries the previous alerts forward
        // under a fresh revision (`WatchStateInbox.accept`), which is last
        // week's list with a new number on it. Reading either as an answer
        // abandoned a live Approve and told the wrist the request was gone.
        //
        // So: wait for a state that came over the link from a connected relay.
        // Only that state may place the request, refuse it, or say it ended.
        //
        // Binding a reply to its question is the exception, and it happens
        // first. Any relayed state carries real ids; whether the phone is
        // reachable *right now* is about whether a message can travel, not
        // about whether those ids are true. Requiring a live link to bind
        // reopened the very window the binding exists to close: while the
        // phone was away, snapshots kept arriving and none of them could bind,
        // so the first settle after the phone returned took whatever was being
        // asked by then as "first sight" and sent the dictation to it. Binding
        // sends nothing by itself, and a state with no id to bind (the cache,
        // or a preserved payload built from it) binds nothing.
        if hasRelayedState, case .answer(let sessionID, _) = held.route,
           bannerAction?.boundPendingID == nil {
            let asking = state.alerts.first { $0.sessionId == sessionID && $0.waitKind == .question }
            _ = bannerAction?.bindsAnswer(to: asking?.pendingId)
        }
        guard hasRelayedState, isLive(state) else {
            if expired { giveUp(waitingReason(for: state)) }
            return
        }
        // The first such state of a hold is the baseline it measures from.
        bannerAction?.noteInstalled(revision: state.relayRevision)
        // The alert the tap named, as that state holds it now. A decision is
        // bound to its approval id, an answer to the session's current question
        // — a banner cannot name a question id.
        let alert: WatchAlert?
        switch held.route {
        case .decide(let sessionID, let approvalID, _):
            alert = state.alerts.first { $0.sessionId == sessionID && $0.approvalId == approvalID }
        case .answer(let sessionID, _):
            alert = state.alerts.first { $0.sessionId == sessionID && $0.waitKind == .question }
        case .open, .ignore:
            alert = nil
        }
        // The iPhone re-sends the context it already sent, so an alert missing
        // from a revision the wrist already had says nothing. Only a strictly
        // newer one that still lacks the request may say the request ended;
        // running out of patience means the wrist never found out, which is a
        // different sentence.
        guard let alert else {
            if bannerAction?.provesRequestGone(currentRevision: state.relayRevision) == true {
                giveUp(.noLongerWaiting)
            } else if expired {
                giveUp(.noState)
            }
            return
        }
        // A prompt the wrist walks question by question is answerable, but not
        // by the one string a banner's Reply collects: the iPhone would refuse
        // it and the dictation would be lost. The walk on the card is the way.
        switch held.route {
        case .decide where !alert.isDecidable, .answer where !alert.isAnswerableInOneString:
            giveUp(.notDecidableHere); return
        default: break
        }
        // The words were dictated for the question on the banner, and a banner
        // cannot name one. Bind to the first question a relayed state shows for
        // this session and hold that binding: otherwise a reply waiting for the
        // link follows the session onto whatever is being asked by the time it
        // travels, and "no" to "Delete the database?" is recorded against
        // "Ship the release?" — accepted by the iPhone's gate, because that id
        // is the live one. `WatchBannerAction.bindsAnswer` is where the promise
        // the card's own draft makes (`WatchAnswerDraft`) is kept here too.
        if case .answer = held.route, bannerAction?.bindsAnswer(to: alert.pendingId) != true {
            giveUp(.noLongerWaiting); return
        }
        if pendingAction.isBusy {
            if expired { giveUp(.busy) }
            return
        }
        bannerAction = nil
        bannerActionTimeout?.cancel()
        let started: Bool
        switch held.route {
        case .decide(_, _, let choice):
            started = submit(alert, choice)
        case .answer(let sessionID, let text):
            started = submitAnswer(sessionId: sessionID, pendingId: alert.pendingId ?? "", text: text)
        case .open, .ignore:
            started = false
        }
        // Both send paths re-run the checks just made, so a refusal here should
        // be unreachable. If one ever is not, it must still leave a sentence: a
        // tap that disappears between "send it" and the wire — under a
        // diagnostic that says it was sent — is the exact failure this path
        // exists to end.
        guard started else {
            giveUp(pendingAction.isBusy ? .busy : .noLongerWaiting)
            return
        }
        WatchNavigationDiagnostics.shared.record("banner.action-sent")
    }

    /// Which link the wrist is waiting on, in the words that are true of it.
    /// "Waiting for an update from your iPhone" is wrong when the update
    /// arrived and it was the Mac that had gone.
    private func waitingReason(for state: WatchDashboardState) -> WatchBannerActionFallback {
        guard hasRelayedState else { return .noState }
        switch state.connection(now: Date(), phoneReachable: canReachPhone) {
        case .macDisconnected: return .macLinkDown
        case .phoneDisconnected, .watchUnreachable: return .linkDown
        case .noData: return .noState
        case .live: return canReachPhone ? .noState : .linkDown
        }
    }

    /// Take down a fallback sentence the world has made untrue, and correct one
    /// it has made merely wrong.
    ///
    /// Each reason is true about a different thing, so each stops being true at
    /// a different moment, and a reason that stops being true rarely means
    /// there is nothing left to say — usually it means something *else* is now
    /// the reason. A sentence that has outlived what it described, sitting
    /// above buttons that disagree with it, is the failure this whole path
    /// exists to avoid; a sentence swapped for the true one costs nothing.
    private func refreshFallback() {
        guard let reason = bannerActionFallback, let route = bannerActionFallbackRoute else { return }
        func clear() {
            bannerActionFallback = nil
            bannerActionFallbackRoute = nil
            bannerActionFallbackPendingID = nil
        }
        // What the wrist would say if the tap were held right now, which is
        // also the answer to "is this still the link that is down".
        let live = state.map(isLive) ?? false
        let standing = standing(of: route)
        switch reason {
        case .noLongerWaiting:
            switch standing {
            case .actionable: clear()
            case .presentButNotHere: bannerActionFallback = .notDecidableHere
            case .absent: break
            }
        case .notDecidableHere:
            switch standing {
            case .actionable: clear()
            // Resolved elsewhere and gone from the snapshot: the card no longer
            // holds the thing this line is about.
            case .absent: bannerActionFallback = .noLongerWaiting
            case .presentButNotHere: break
            }
        case .linkDown, .macLinkDown:
            // The chain has two links and either can be the broken one. When
            // the phone comes back and the Mac is still down, "can't reach your
            // iPhone" is false and contradicts the card's own block two lines
            // below; the sentence becomes the Mac's, not nothing.
            guard live else {
                if let state {
                    let now = waitingReason(for: state)
                    if now != reason, now == .linkDown || now == .macLinkDown {
                        bannerActionFallback = now
                    }
                }
                return
            }
            // A live link and the request still there: the buttons work, so the
            // sentence is spent. Gone instead: say so, rather than implying a
            // tap is still waiting on a link that has returned.
            switch standing {
            case .actionable: clear()
            case .presentButNotHere: bannerActionFallback = .notDecidableHere
            case .absent: bannerActionFallback = .noLongerWaiting
            }
        case .busy:
            guard !pendingAction.isBusy else { return }
            switch standing {
            case .actionable: clear()
            case .presentButNotHere: bannerActionFallback = .notDecidableHere
            case .absent: bannerActionFallback = .noLongerWaiting
            }
        case .noState:
            // "It wasn't sent" stays true once the update finally arrives.
            // This one leaves with the card.
            break
        }
    }

    private enum FallbackStanding { case actionable, presentButNotHere, absent }

    /// Where the request a sentence was about stands in the state on screen.
    private func standing(of route: WatchNotificationResponseRoute) -> FallbackStanding {
        guard let state else { return .absent }
        switch route {
        case .decide(let sessionID, let approvalID, _):
            guard let alert = state.alerts.first(where: {
                $0.sessionId == sessionID && $0.approvalId == approvalID
            }) else { return .absent }
            return alert.isDecidable ? .actionable : .presentButNotHere
        case .answer(let sessionID, _):
            // A reply's sentence keeps its own question: the one that replaced
            // it is what the sentence is explaining, not a reason to drop it.
            // And a reply that never got far enough to bind one has no question
            // to be about, so the next unrelated thing this session asks is not
            // its request coming back.
            guard let bound = bannerActionFallbackPendingID else { return .absent }
            guard let alert = state.alerts.first(where: {
                $0.sessionId == sessionID && $0.pendingId == bound
            }) else { return .absent }
            return alert.isAnswerableInOneString ? .actionable : .presentButNotHere
        case .open, .ignore:
            return .absent
        }
    }

    /// The tap an attempt earns when it stops travelling. Only a transition out
    /// of `sending` counts, so a state that merely re-publishes the same phase
    /// stays quiet, and only while the wrist is looking — `WKInterfaceDevice.
    /// play` does nothing in the background anyway.
    private func feelActionOutcome(from old: WatchSessionActionState, to new: WatchSessionActionState) {
        guard isForeground || isDemo,
              let attempt = new.action, old.action?.attemptId == attempt.attemptId,
              old.action?.phase == .sending, attempt.phase != .sending else { return }
        WatchHapticPlayer.shared.play(WatchHaptics.actionOutcome(attempt.phase),
                                      reason: "action \(attempt.phase)")
    }

    /// The launch input's answer, for the one card in front of the wearer.
    ///
    /// The task detail is a sheet *over* the home screen, so both cards exist
    /// at once and both would ask to present a page — which presents neither.
    /// Only the focused session gets it, and only once.
    func consumeDemoAnswerDraft(for sessionId: String) -> String? {
        guard let draft = demoAnswerDraft else { return nil }
        let focused = taskLink?.sessionID ?? state?.topAlert?.sessionId
        guard focused == sessionId else { return nil }
        demoAnswerDraft = nil
        return draft
    }

    func refreshTask() {
        guard !isDemo else { return }
        refreshTimeout?.cancel()
        refreshAttempt = nil
        taskRefreshFailed = false
        isRefreshingTask = false
        guard let source = state?.sourceID, let epoch = state?.pairingEpoch,
              let session, session.activationState == .activated else {
            taskRefreshFailed = true; return
        }
        // sendMessage from the Watch can wake its companion; do not require
        // the iPhone UI or stream to already be active.
        let request = WatchRefreshRequest(sourceID: source, pairingEpoch: epoch)
        guard let data = try? JSONEncoder().encode(request) else { taskRefreshFailed = true; return }
        refreshAttempt = request
        isRefreshingTask = true
        WatchNavigationDiagnostics.shared.record("refresh.request")
        refreshTimeout = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(12))
            guard !Task.isCancelled else { return }
            self?.finishRefresh(request, reply: nil)
        }
        session.sendMessage([WatchRefreshRequest.messageKey: data], replyHandler: { @Sendable [weak self] reply in
            let result = (reply[WatchRefreshReply.messageKey] as? Data).flatMap {
                try? JSONDecoder().decode(WatchRefreshReply.self, from: $0)
            }
            Task { @MainActor [weak self] in self?.finishRefresh(request, reply: result) }
        }, errorHandler: { @Sendable [weak self] _ in
            Task { @MainActor [weak self] in self?.finishRefresh(request, reply: nil) }
        })
    }

    private func finishRefresh(_ request: WatchRefreshRequest, reply: WatchRefreshReply?) {
        guard refreshAttempt?.id == request.id else { return }
        refreshAttempt = nil
        refreshTimeout?.cancel()
        isRefreshingTask = false
        guard let current = state, request.accepts(current), let fresh = reply?.snapshot(for: request) else {
            taskRefreshFailed = true
            WatchNavigationDiagnostics.shared.record("refresh.failed")
            return
        }
        receive(WatchStateInbox.encode(fresh))
        taskRefreshFailed = false
        WatchNavigationDiagnostics.shared.record("refresh.received")
    }

    func cancelTaskRefresh() {
        refreshTimeout?.cancel()
        refreshAttempt = nil
        isRefreshingTask = false
        taskRefreshFailed = false
    }

    func openTask(_ url: URL) {
        WatchNavigationDiagnostics.shared.record("route.url")
        if let selection = WatchQuotaSelection(url: url) {
            taskLink = nil
            quotaSelection = selection
            return
        }
        guard let link = WatchTaskLink(url: url) else { return }
        quotaSelection = nil
        taskLink = link
    }

    /// A session the wrist was pointed at by id — a Needs-you or Results row,
    /// or the tap on a mirrored notification. The link is minted from the
    /// state on screen, so it is bound to the Mac, the pairing and (for a
    /// result) the exact round the wearer is about to read. A target with a
    /// missing identity is held until the first relay arrives. With an identity,
    /// an unknown target opens an unavailable page instead of waiting forever.
    func openSession(_ sessionID: String) {
        WatchNavigationDiagnostics.shared.record("route.session")
        guard let state, let source = state.sourceID, !source.isEmpty,
              let epoch = state.pairingEpoch, !epoch.isEmpty else {
            taskLink = nil
            quotaSelection = nil
            WatchNavigationDiagnostics.shared.record("route.waiting-state")
            pendingSessionID = sessionID
            pendingPairingEpoch = self.state?.pairingEpoch
            return
        }
        pendingSessionID = nil
        quotaSelection = nil
        WatchNavigationDiagnostics.shared.record("route.present-task")
        taskLink = WatchTaskLink(sourceID: source, pairingEpoch: epoch, sessionID: sessionID,
                                 completionID: state.task(sessionID)?.completionID)
    }

    /// A session named before the state could place it (`openSession`).
    private var pendingSessionID: String?
    private var pendingPairingEpoch: String?

    /// Live Activity continuation is a transient lookup, never a replayable action.
    func openLiveActivity(_ activityID: String?) {
        cancelPendingNavigation()
        activityOpenError = nil
        guard let activityID, !activityID.isEmpty else {
            WatchNavigationDiagnostics.shared.record("activity.missing-id")
            activityOpenError = "This activity no longer identifies a task. Open Tasks from Home."
            return
        }
        guard let source = state?.sourceID, let epoch = state?.pairingEpoch,
              let session, session.activationState == .activated, session.isReachable else {
            WatchNavigationDiagnostics.shared.record("activity.phone-unavailable")
            activityOpenError = "Open VibeBuddy on your iPhone, then try again."
            return
        }
        let request = WatchActivityOpenRequest(activityID: activityID, sourceID: source, pairingEpoch: epoch)
        guard let data = try? JSONEncoder().encode(request) else { return }
        WatchNavigationDiagnostics.shared.record("activity.request")
        activityRequest = request
        isOpeningActivity = true
        activityTimeout = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            self?.finishActivity(request, reply: nil, error: "The iPhone did not respond. Try again.")
        }
        session.sendMessage([WatchActivityOpenRequest.messageKey: data], replyHandler: { @Sendable [weak self] reply in
            let data = reply[WatchActivityOpenReply.messageKey] as? Data
            let result = data.flatMap { try? JSONDecoder().decode(WatchActivityOpenReply.self, from: $0) }
            Task { @MainActor [weak self] in
                self?.finishActivity(request, reply: result, error: "This task is no longer available. Open Tasks from Home.")
            }
        }, errorHandler: { @Sendable [weak self] _ in
            Task { @MainActor [weak self] in
                self?.finishActivity(request, reply: nil, error: "Open VibeBuddy on your iPhone, then try again.")
            }
        })
    }

    private func finishActivity(_ request: WatchActivityOpenRequest, reply: WatchActivityOpenReply?, error: String) {
        // A timeout, new tap, cancellation or source change consumes this attempt.
        guard activityRequest?.requestID == request.requestID else {
            WatchNavigationDiagnostics.shared.record("activity.late-result")
            return
        }
        cancelPendingNavigation()
        guard let link = reply?.validatedLink(for: request, state: state) else {
            WatchNavigationDiagnostics.shared.record("activity.unresolved")
            activityOpenError = error
            return
        }
        WatchNavigationDiagnostics.shared.record("activity.resolved")
        if isForeground { openTask(link.url) }
        else { resolvedActivityLink = link }
    }

    private func cancelActivityOpen() {
        resolvedActivityLink = nil
        activityRequest = nil
        activityTimeout?.cancel()
        activityTimeout = nil
        isOpeningActivity = false
    }

    func cancelPendingNavigation() {
        UserDefaults.standard.removeObject(forKey: "watch.pendingNotificationIntent")
        cancelActivityOpen()
        pendingSessionID = nil
        pendingPairingEpoch = nil
    }

    /// Leaving a card withdraws the banner decision made about it, and takes
    /// the sentence explaining the last one with it.
    ///
    /// The trigger is a card that *was* up going away — not "there is no card
    /// right now". Those are different, and reading the second as the first
    /// dropped the tap in silence twice over: `openSession` clears `taskLink`
    /// and `quotaSelection` on its way to setting the other, so every
    /// navigation passes through a cardless moment that is not a departure;
    /// and a hold that is still waiting for the state that can place its
    /// session has no card yet either, which is what the patience and its
    /// `.noState` ending are for, not grounds to forget the decision.
    private func withdrawBannerAction() {
        bannerAction = nil
        bannerActionTimeout?.cancel()
        bannerActionFallback = nil
        bannerActionFallbackRoute = nil
        bannerActionFallbackPendingID = nil
    }

    /// Called only by the exact detail body after it has appeared. Viewing is
    /// viewing: for a wait it tells the Mac the request was seen (so the
    /// missed-wait clock stops) and nothing more. A completion summary is not
    /// the full result: only markCompletionRead records that explicit intent.
    func viewed(_ link: WatchTaskLink) {
        if !isDemo, let read = waitRead(for: link), let session, isPhoneReachable {
            let request = WatchWaitReadRequest(pairingEpoch: link.pairingEpoch, read: read)
            if let payload = try? JSONEncoder().encode(request) {
                // Best effort only: no approval and no claim that an offline read synced.
                session.sendMessage([WatchWaitReadRequest.messageKey: payload],
                                    replyHandler: { @Sendable _ in }, errorHandler: { @Sendable _ in })
            }
        }
    }

    /// The detail button supplies the round that was actually displayed.
    /// Unreachable phones keep an explicit, exact-round retry on this Watch.
    func markCompletionRead(_ link: WatchTaskLink) {
        completionQueue.markRead(link, state: state)
        persistCompletions()
        flushCompletions()
    }

    /// The wait this link is looking at, if it is looking at one. A followed
    /// task carries it; an alert that is not followed carries the same facts
    /// under its own names.
    private func waitRead(for link: WatchTaskLink) -> WaitReadRequest? {
        if let task = link.task(in: state), task.presentation == .requiresInput {
            return WaitReadRequest(sourceID: link.sourceID, sessionID: link.sessionID,
                                   statusSince: task.statusSince, waitKind: task.waitKind ?? .question,
                                   pendingID: task.pendingID)
        }
        if let alert = link.alert(in: state) {
            return WaitReadRequest(sourceID: link.sourceID, sessionID: link.sessionID,
                                   statusSince: alert.waitingSince, waitKind: alert.waitKind,
                                   pendingID: alert.approvalId ?? alert.pendingId)
        }
        return nil
    }

    private func persistCompletions() {
        // Demo interactions must never replace the live cache or pending reads.
        guard !isDemo else { return }
        retryAfter = retryAfter.filter { completionQueue.links.contains($0.key) }
        retryCount = retryCount.filter { completionQueue.links.contains($0.key) }
        if let state, WatchComplicationStore.save(state, queue: completionQueue) {
            WidgetCenter.shared.reloadTimelines(ofKind: WatchComplicationStore.kind)
            WidgetCenter.shared.reloadTimelines(ofKind: WatchComplicationStore.quotaKind)
        }
    }

    private func flushCompletions() {
        guard !isDemo, completionAttempt == nil, isPhoneReachable,
              let session, session.isReachable, let state,
              let link = completionQueue.links.first(where: {
                  $0.sourceID == state.sourceID && $0.pairingEpoch == state.pairingEpoch
                    && (retryAfter[$0] ?? .distantPast) <= Date()
              }) else { return }
        let request = WatchCompletionRequest(attemptID: UUID().uuidString, link: link)
        guard let payload = try? JSONEncoder().encode(request) else { return }
        completionAttempt = request
        session.sendMessage([WatchCompletionRequest.messageKey: payload], replyHandler: { @Sendable [weak self] reply in
            let data = reply[WatchCompletionResult.messageKey] as? Data
            let result = data.flatMap { try? JSONDecoder().decode(WatchCompletionResult.self, from: $0) }
            Task { @MainActor [weak self] in self?.completionReturned(result, request: request) }
        }, errorHandler: { @Sendable [weak self] _ in
            Task { @MainActor [weak self] in self?.completionReturned(nil, request: request) }
        })
        // WatchConnectivity replies are not guaranteed to arrive. Release only
        // this attempt; the persisted exact-round record remains retryable.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(20))
            self?.completionReturned(nil, request: request)
        }
    }

    private func completionReturned(_ result: WatchCompletionResult?, request: WatchCompletionRequest) {
        guard completionAttempt?.attemptID == request.attemptID else { return }
        guard result == nil || result?.attemptID == request.attemptID else { return }
        completionAttempt = nil
        let tries = min(4, (retryCount[request.link] ?? 0) + 1)
        retryCount[request.link] = tries
        retryAfter[request.link] = Date().addingTimeInterval(min(60, 5 * pow(2, Double(tries - 1))))
        if let result { completionQueue.received(result.outcome, for: request.link) }
        // A receipt retires this retry only. The face still follows snapshots.
        if let state { completionQueue.reconcile(with: state); persistCompletions() }
        flushCompletions()
    }

    /// Whether a decision could be sent at all. Demo Mode resolves its samples
    /// locally, so it needs no phone.
    var canReachPhone: Bool { isDemo || isPhoneReachable }

    /// Ask the iPhone to resolve this approval. A second tap while an action is
    /// in flight does nothing — `WatchSessionActionState` refuses to start a
    /// new attempt — so the decision cannot be submitted twice.
    ///
    /// Returns whether an attempt actually started. A button on a card ignores
    /// that — the card either shows the attempt or goes on showing the request.
    /// A banner decision needs it: there is nothing else on screen that would
    /// say the tap went nowhere.
    @discardableResult
    func submit(_ alert: WatchAlert, _ choice: WatchApprovalChoice) -> Bool {
        guard let state, isLive(state),
              state.alerts.contains(where: { $0.sessionId == alert.sessionId && $0.approvalId == alert.approvalId }),
              let request = pendingAction.begin(alert: alert, choice: choice,
                                                attemptId: UUID().uuidString)
        else { return false }
        send(request)
        return true
    }

    /// Ask the iPhone to answer the question this text was written for.
    ///
    /// The binding is the argument, not the screen. `pendingId` comes from the
    /// draft — captured when the words were made — and is matched against the
    /// alert the *current* state holds. A confirmation page left open while the
    /// Mac answered the question and the agent asked the next one therefore
    /// sends nothing, rather than delivering an answer to a question nobody
    /// read. Returns false in exactly that case, so the page can say so instead
    /// of closing as though it had worked.
    ///
    /// A second tap while one is in flight sends nothing — the state machine
    /// refuses a new attempt — so a question cannot be answered twice.
    @discardableResult
    func submitAnswer(sessionId: String, pendingId: String, text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let state, !trimmed.isEmpty, !pendingId.isEmpty,
              let current = state.alerts.first(where: {
                  $0.sessionId == sessionId && $0.isAnswerable && $0.pendingId == pendingId
              })
        else { return false }
        guard let request = pendingAction.begin(alert: current, answer: trimmed,
                                                attemptId: UUID().uuidString)
        // Keep this draft open when another action owns the in-flight slot.
        else { return false }
        // Same order as a stop: the attempt exists before the link is judged,
        // so a confirmation tapped over a dead link leaves a sentence on screen
        // instead of dismissing in silence.
        guard isLive(state) else {
            pendingAction.fail(attemptId: request.attemptId)
            return true
        }
        send(request)
        return true
    }

    /// Ask the iPhone to answer every question of the prompt these picks were
    /// made for.
    ///
    /// Same binding as `submitAnswer`: the prompt's identity comes from the
    /// walk, captured when it began, and is matched against the alert the
    /// *current* state holds. A walk left open while the Mac answered the
    /// prompt and the agent asked the next one sends nothing, and says so.
    /// The set is checked here as the iPhone will check it, so nothing partial
    /// ever leaves the wrist.
    @discardableResult
    func submitAnswers(sessionId: String, pendingId: String, answers: QuestionAnswers) -> Bool {
        guard let state, !pendingId.isEmpty,
              let current = state.alerts.first(where: {
                  $0.sessionId == sessionId && $0.isAnswerable && $0.pendingId == pendingId
              })
        else { return false }
        guard let request = pendingAction.begin(alert: current, answers: answers,
                                                attemptId: UUID().uuidString)
        else { return false }
        guard isLive(state) else {
            pendingAction.fail(attemptId: request.attemptId)
            return true
        }
        send(request)
        return true
    }

    /// Ask the iPhone to end the turn this confirmation was opened about.
    ///
    /// The turn is the argument, not the screen. `statusSince` comes from the
    /// intent captured by the first tap, and is matched against the task the
    /// *current* state holds — a confirmation page is exactly the window in
    /// which one turn can end and the next begin, and the wrist must not carry
    /// a stop across that boundary. Returns false when it would have, so the
    /// page says so instead of closing as though it had worked.
    ///
    /// Destructive, and confirmed on its own screen before it gets here.
    @discardableResult
    func submitStop(sessionID: String, statusSince: Date) -> Bool {
        guard let state,
              let current = state.followedTasks.first(where: { $0.sessionID == sessionID }),
              current.stop?.isOffered == true,
              abs(current.statusSince.timeIntervalSince1970 - statusSince.timeIntervalSince1970)
                  < WatchSessionActionGate.statusSinceTolerance
        else { return false }
        guard let request = pendingAction.begin(stop: current, attemptId: UUID().uuidString)
        // A different in-flight action must not dismiss this confirmation.
        else { return false }
        // The attempt is started before the link is judged, so a confirmation
        // tapped while the phone or the Mac is unreachable leaves something on
        // screen. A destructive action that dismisses its own sheet in silence
        // is indistinguishable, from the wrist, from one that worked.
        guard isLive(state) else {
            pendingAction.fail(attemptId: request.attemptId)
            return true
        }
        send(request)
        return true
    }

    /// Whether an action could actually travel right now: the phone in range,
    /// and the phone still talking to the Mac.
    private func isLive(_ state: WatchDashboardState) -> Bool {
        canReachPhone && state.connection(now: Date(), phoneReachable: canReachPhone) == .live
    }

    private func send(_ request: WatchSessionActionRequest) {
        if isDemo {
            resolveLocally(request)
            return
        }
        guard let session, session.isReachable,
              let payload = try? JSONEncoder().encode(request) else {
            pendingAction.fail(attemptId: request.attemptId)
            return
        }
        // Bound the wait independently of WCSession, as Home Assistant does.
        // Allow the phone's snapshot + action HTTP requests (10s + 15s), plus
        // wake-up and transport time. A missing receipt is not a failed action.
        actionReplyTimeout?.cancel()
        actionReplyTimeout = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(60)) }
            catch { return }
            self?.pendingAction.lost(attemptId: request.attemptId)
        }
        session.sendMessage(
            [WatchSessionActionRequest.messageKey: payload],
            replyHandler: { @Sendable [weak self] reply in
                // The message went out. A reply we cannot read says nothing
                // about whether the Mac acted, so it is a lost receipt rather
                // than a delivery failure — the wrist must not claim either way.
                let data = reply[WatchSessionActionResult.messageKey] as? Data
                let result = data.flatMap { try? JSONDecoder().decode(WatchSessionActionResult.self, from: $0) }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if self.pendingAction.action?.attemptId == request.attemptId {
                        self.actionReplyTimeout?.cancel()
                    }
                    if let result { self.pendingAction.apply(result) }
                    else { self.pendingAction.lost(attemptId: request.attemptId) }
                }
            },
            errorHandler: { @Sendable [weak self] error in
                // WatchConnectivity reports both endings through this one
                // handler, and they are not the same thing to say out loud. A
                // reply that timed out or a delivery that failed means the
                // message may well have arrived; anything else — not reachable,
                // session not activated, no paired device, payload too large —
                // means it never left, and that one may plainly be tried again.
                let lost = Self.receiptWasLost(error)
                Task { @MainActor [weak self] in
                    if self?.pendingAction.action?.attemptId == request.attemptId {
                        self?.actionReplyTimeout?.cancel()
                    }
                    if lost { self?.pendingAction.lost(attemptId: request.attemptId) }
                    else { self?.pendingAction.fail(attemptId: request.attemptId) }
                }
            })
    }

    /// Whether this `sendMessage` error leaves the outcome genuinely unknown.
    ///
    /// A failed or timed-out reply may follow a delivered action. An unrecognised
    /// error is read as *lost* rather than
    /// as *not sent*: claiming a message never left is the assertion that costs
    /// something when it is wrong.
    nonisolated private static func receiptWasLost(_ error: Error) -> Bool {
        guard let code = (error as? WCError)?.code else { return true }
        switch code {
        case .notReachable, .sessionNotActivated, .sessionInactive, .sessionMissingDelegate,
             .deviceNotPaired, .watchAppNotInstalled, .payloadTooLarge, .payloadUnsupportedTypes,
             .invalidParameter:
            return false
        default:
            return true
        }
    }

    /// Demo Mode: the sample resolves the way a real one does — the action is
    /// accepted, and the button goes away only when the next state says the
    /// world changed, not because it was tapped.
    private func resolveLocally(_ request: WatchSessionActionRequest) {
        pendingAction.apply(WatchSessionActionResult(attemptId: request.attemptId, outcome: .accepted))
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, let current = self.state else { return }
            switch request.action {
            case .approval(let id, _): self.install(current.resolvingApproval(id))
            case .stop: self.install(current.resolvingStop(request.sessionId))
            case .answer(let pendingId, _), .answerAll(let pendingId, _):
                self.install(current.resolvingAnswer(pendingId))
            }
        }
    }

    /// Record a new state and let any in-flight decision see it.
    private func install(_ next: WatchDashboardState) {
        if let epoch = pendingPairingEpoch, let nextEpoch = next.pairingEpoch, epoch != nextEpoch {
            cancelPendingNavigation()
        }
        if state?.sourceID != next.sourceID || state?.pairingEpoch != next.pairingEpoch {
            // A different Mac or a different pairing: nothing in flight was
            // ever about this world. Clear it rather than let it describe one.
            cancelActivityOpen()
            cancelTaskRefresh()
            pendingAction = WatchSessionActionState()
        }
        state = next
        hasRelayedState = true
        pendingAction.reconcile(with: next)
        // After the reconcile, never before it: the snapshot that retires an
        // attempt is the same one that would otherwise be judged against a slot
        // still holding it.
        refreshFallback()
        completionQueue.reconcile(with: next)
        if let pendingSessionID { openSession(pendingSessionID) }
        settleBannerAction(expired: false)
        persistCompletions()
        if let request = completionAttempt,
           request.link.sourceID != next.sourceID || request.link.pairingEpoch != next.pairingEpoch {
            completionAttempt = nil
        }
        flushCompletions()
        feel(next)
    }

    /// The state that was already on screen before this launch. It is the
    /// baseline every later boundary is measured against, and it is never
    /// itself played: a backlog is not news.
    private func seedHaptics(_ state: WatchDashboardState) {
        _ = haptics.advance(to: state, now: Date())
    }

    /// Demo Mode only, behind its own launch input: hand the store a second
    /// state a moment after launch so a transition — and the tap it earns —
    /// can be exercised in the Simulator, which has neither a paired iPhone nor
    /// a haptic engine. Nothing else in Demo Mode changes.
    private func rehearseHapticTransition() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard let self, let current = self.state else { return }
            var next = current
            next.alerts.append(WatchAlert(
                sessionId: "demo-watch-haptic", agent: .codex, project: "haptic-rehearsal",
                waitKind: .question, summary: "Waiting on an answer",
                request: "Which rhythm did you just feel?",
                handling: .remoteAvailable, waitingSince: Date()))
            next.counts.needsResponse += 1
            next.presentation.requiresInput += 1
            self.install(next)
        }
    }

    /// Say — in a rhythm rather than in words — what just changed.
    ///
    /// The boundary is recorded before anything is played, so a state that
    /// arrives while the wrist is down is remembered as already-known rather
    /// than replayed as news later.
    private func feel(_ state: WatchDashboardState) {
        let now = Date()
        let earned = haptics.advance(to: state, now: now)
        guard isForeground, !earned.isEmpty else { return }
        guard let cue = WatchHaptics.cue(forAnyOf: earned,
                                         categories: state.effectiveCategories,
                                         quiet: state.isQuiet(at: now)) else {
            WatchHapticPlayer.shared.play([], reason: "snapshot \(earned.map(\.rawValue).joined(separator: "+"))")
            return
        }
        WatchHapticPlayer.shared.play(cue.beats, reason: "snapshot \(cue.category.rawValue)")
    }

    func becameActive() {
        WatchNavigationDiagnostics.shared.record("window.active")
        guard !isDemo, let session else { isForeground = true; return }
        // Incorporate the actual latest context before sending persisted work.
        // This one is taken while still counted as background on purpose: what
        // the phone wrote before you raised your wrist is the backlog, and its
        // mirrored notification has already said it. Only what arrives *after*
        // the app is up is news the wrist should tap out.
        // An attempt of this wrist's own can come to rest inside that backlog:
        // a banner decision sent seconds ago, answered while the window was
        // still coming up. The backlog is silent by design, but a reply to this
        // wrist's own tap is not backlog, and `feelActionOutcome` will have
        // stayed quiet for it — so it is replayed once the wrist counts as
        // looking.
        let settling = pendingAction.action
        receive(session.receivedApplicationContext[WatchStateInbox.contextKey] as? Data)
        isForeground = true
        if let landed = pendingAction.action, landed.attemptId == settling?.attemptId,
           settling?.phase == .sending, landed.phase != .sending {
            WatchHapticPlayer.shared.play(WatchHaptics.actionOutcome(landed.phase),
                                          reason: "action \(landed.phase)")
        }
        if let data = UserDefaults.standard.data(forKey: "watch.pendingNotificationIntent") {
            UserDefaults.standard.removeObject(forKey: "watch.pendingNotificationIntent")
            if let intent = try? JSONDecoder().decode(WatchNotificationIntent.self, from: data),
               let link = intent.target(in: state) {
                WatchNavigationDiagnostics.shared.record("notification.target-restored")
                openTask(link.url)
            }
        }
        if let link = resolvedActivityLink {
            resolvedActivityLink = nil
            if link.sourceID == state?.sourceID, link.pairingEpoch == state?.pairingEpoch {
                openTask(link.url)
            }
        }
        linkChanged(reachable: session.isReachable)
    }

    func resignedActive() {
        WatchNavigationDiagnostics.shared.record("window.inactive")
        isForeground = false
    }

    private func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        self.session = session
        session.delegate = self
        session.activate()
    }

    private func scheduleDiagnostics() {
        diagnosticDelivery?.cancel()
        diagnosticDelivery = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self, !self.isDemo,
                  let session = self.session, session.activationState == .activated,
                  let data = WatchNavigationDiagnostics.shared.payload else { return }
            try? session.updateApplicationContext(["vibebuddy.watch.navigationDiagnostics": data])
        }
    }

    fileprivate func linkChanged(reachable: Bool) {
        scheduleDiagnostics()
        isPhoneReachable = reachable
        flushCompletions()
        refreshFallback()
        settleBannerAction(expired: false)
    }

    /// Take a payload from the relay. A payload that cannot be decoded leaves
    /// the last known good state on screen rather than blanking the Watch.
    fileprivate func receive(_ payload: Data?) {
        guard inbox.accept(payload), let accepted = inbox.state else { return }
        install(accepted)
    }
}

extension WatchStateStore: WCSessionDelegate {
    nonisolated func session(_ session: WCSession,
                             activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {
        // WatchConnectivity holds the newest context across launches; take it
        // now rather than waiting for the iPhone to have something new to say.
        // Only the payload crosses the actor boundary — `[String: Any]` is not
        // Sendable, and nothing else in the context is ours.
        let payload = session.receivedApplicationContext[WatchStateInbox.contextKey] as? Data
        let reachable = session.isReachable
        Task { @MainActor [weak self] in
            self?.receive(payload)
            self?.linkChanged(reachable: reachable)
        }
    }

    /// The iPhone's newest state. It arrives whether the phone wrote it from the
    /// foreground, from behind a locked screen, or just before it was suspended:
    /// the system carries the context on after the sending app exits.
    nonisolated func session(_ session: WCSession,
                             didReceiveApplicationContext applicationContext: [String: Any]) {
        let payload = applicationContext[WatchStateInbox.contextKey] as? Data
        Task { @MainActor [weak self] in self?.receive(payload) }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor [weak self] in self?.linkChanged(reachable: reachable) }
    }
}
