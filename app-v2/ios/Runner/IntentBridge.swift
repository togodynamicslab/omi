import EventKit
import Flutter
import FoundationModels
import Foundation
import UIKit
import UserNotifications

/// Bridge between Flutter and Apple's on-device Foundation Models for the
/// Nooto intent dispatcher feature (formerly `app-v2/native-poc/ios/`).
///
/// Dart pushes natural-language text over a method channel; we parse it via
/// `LanguageModelSession` + `@Generable LLMIntentDraft`, narrow to the strict
/// `NootoIntent` enum, and dispatch to one of three system surfaces:
///   - alarms / timers → Shortcuts URL (NootoSetAlarm / NootoStartTimer)
///   - calendar events → EventKit EKEvent.save
///   - reminders       → EventKit EKReminder.save
/// Unknown intents are surfaced back to Dart as `.noOp` with a reason string.
///
/// Method channel contract (`com.nooto.intent_bridge`):
///   checkAvailability() -> { available: Bool, reason: String? }
///   parseAndDispatch({ text: String }) -> {
///       parsedJson: String,         // pretty-printed JSON of NootoIntent
///       intentKind: String,         // set_alarm | start_timer | add_event | make_reminder | unknown
///       dispatchStatus: String,     // success | noop | failed
///       dispatchReason: String?,    // populated when status != success
///       latencyMs: Int,
///       blockedBySafetyClassifier: Bool
///   }
///
/// Apple Intelligence is required: caller should `checkAvailability` and
/// guard the UI. Calendar / Reminders trigger their own permission prompts
/// on first dispatch — Dart can also surface the failure reason if denied.
@available(iOS 26.0, *)
class IntentBridge {
    static let channelName = "com.nooto.intent_bridge"
    private static let llmTimeoutSeconds: TimeInterval = 10.0

    private let channel: FlutterMethodChannel
    private let session: LanguageModelSession
    private var prewarmed: Bool = false

    init(messenger: FlutterBinaryMessenger) {
        channel = FlutterMethodChannel(name: IntentBridge.channelName, binaryMessenger: messenger)
        // Use permissive guardrails: our prompt is internal and well-defined.
        // (The unsafe-content classifier still fires on some "X minute timer"
        // phrasings — we surface those as Unknown back to Dart.)
        let model = SystemLanguageModel(
            useCase: .general,
            guardrails: .permissiveContentTransformations
        )
        let instructions = Self.loadInstructions()
        session = LanguageModelSession(model: model, instructions: instructions)
        channel.setMethodCallHandler { [weak self] call, result in
            self?.handle(call, result: result)
        }
    }

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "checkAvailability":
            let model = SystemLanguageModel.default
            switch model.availability {
            case .available:
                result(["available": true, "reason": NSNull()])
                if !prewarmed {
                    prewarmed = true
                    session.prewarm(promptPrefix: nil)
                }
            case .unavailable(let reason):
                result(["available": false, "reason": Self.describeAvailability(reason)])
            @unknown default:
                result(["available": false, "reason": "Apple Intelligence availability is unknown."])
            }
        case "parseAndDispatch":
            guard let args = call.arguments as? [String: Any], let text = args["text"] as? String else {
                result(FlutterError(code: "BAD_ARGS", message: "expected { text: String }", details: nil))
                return
            }
            Task { @MainActor in
                let payload = await self.parseAndDispatch(text: text)
                result(payload)
            }
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - Parse + dispatch

    @MainActor
    private func parseAndDispatch(text: String) async -> [String: Any] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return self.payload(
                intent: .unknown(reason: "empty input"),
                outcome: .noOp,
                latencyMs: 0,
                blockedBySafety: false
            )
        }

        // Inject "Now: <weekday YYYY-MM-DD HH:mm>" so the model has an anchor
        // for "tomorrow", "Friday", "this afternoon", etc.
        let nowFormatter = DateFormatter()
        nowFormatter.locale = Locale(identifier: "en_US_POSIX")
        nowFormatter.timeZone = TimeZone.current
        nowFormatter.dateFormat = "EEEE yyyy-MM-dd HH:mm"
        let nowString = nowFormatter.string(from: Date())

        let start = ContinuousClock.now
        do {
            let draft: LLMIntentDraft = try await withTimeout(seconds: Self.llmTimeoutSeconds) { [session] in
                let response = try await session.respond(
                    to: "Now: \(nowString). Input: \(trimmed)",
                    generating: LLMIntentDraft.self
                )
                return response.content
            }
            let elapsedMs = Int(start.duration(to: .now).milliseconds)
            let intent = NootoIntent.from(draft: draft)
            let outcome = await Self.dispatch(intent)
            return payload(intent: intent, outcome: outcome, latencyMs: elapsedMs, blockedBySafety: false)
        } catch is TimeoutError {
            return payload(
                intent: .unknown(reason: "timeout after \(Int(Self.llmTimeoutSeconds))s"),
                outcome: .noOp,
                latencyMs: Int(Self.llmTimeoutSeconds * 1000),
                blockedBySafety: false
            )
        } catch let error as LanguageModelSession.GenerationError {
            let elapsedMs = Int(start.duration(to: .now).milliseconds)
            let desc = (error.errorDescription ?? "\(error)").lowercased()
            let blocked = desc.contains("unsafe") || desc.contains("guardrail")
            let reason = blocked
                ? "blocked by Apple Intelligence safety classifier"
                : "generation error: \(error.errorDescription ?? "\(error)")"
            return payload(
                intent: .unknown(reason: reason),
                outcome: .noOp,
                latencyMs: elapsedMs,
                blockedBySafety: blocked
            )
        } catch {
            let elapsedMs = Int(start.duration(to: .now).milliseconds)
            return payload(
                intent: .unknown(reason: "parser error: \(error.localizedDescription)"),
                outcome: .noOp,
                latencyMs: elapsedMs,
                blockedBySafety: false
            )
        }
    }

    private func payload(
        intent: NootoIntent,
        outcome: DispatchOutcome,
        latencyMs: Int,
        blockedBySafety: Bool
    ) -> [String: Any] {
        return [
            "parsedJson": Self.prettyJSON(intent),
            "intentKind": Self.intentKind(intent),
            "dispatchStatus": outcome.status,
            "dispatchReason": outcome.reason ?? NSNull(),
            "latencyMs": latencyMs,
            "blockedBySafetyClassifier": blockedBySafety,
        ]
    }

    // MARK: - Dispatch

    enum DispatchOutcome {
        case success
        case noOp
        case failed(reason: String)

        var status: String {
            switch self {
            case .success: return "success"
            case .noOp: return "noop"
            case .failed: return "failed"
            }
        }
        var reason: String? {
            if case let .failed(reason) = self { return reason }
            return nil
        }
    }

    @MainActor
    static func dispatch(_ intent: NootoIntent) async -> DispatchOutcome {
        switch intent {
        case let .setAlarm(time, label, recurrence):
            return await dispatchAlarmAsReminder(time: time, label: label, recurrence: recurrence)
        case let .startTimer(seconds, label):
            return await dispatchTimerAsReminder(seconds: seconds, label: label)
        case let .addEvent(title, start, durationMinutes, location, notes):
            return await dispatchEvent(title: title, start: start, durationMinutes: durationMinutes, location: location, notes: notes)
        case let .makeReminder(title, due, notes):
            return await dispatchReminder(title: title, due: due, notes: notes)
        case .unknown:
            return .noOp
        }
    }

    /// Dispatch an alarm as an EKReminder with an attached EKAlarm at the
    /// target clock time. The iOS Reminders system fires the notification
    /// at the scheduled time — real, persistent, no Dart timer needed.
    private static func dispatchAlarmAsReminder(time: String, label: String?, recurrence: Recurrence) async -> DispatchOutcome {
        let parts = time.split(separator: ":").map(String.init)
        guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]) else {
            return .failed(reason: "invalid time '\(time)'")
        }
        let now = Date()
        var fireAt = Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: now) ?? now
        if fireAt <= now {
            fireAt = Calendar.current.date(byAdding: .day, value: 1, to: fireAt) ?? fireAt
        }
        let title = (label?.isEmpty == false ? label! : "Alarm")
        // Recurrence is captured as a note for now — EKReminder's recurrence
        // model needs an EKRecurrenceRule object; PoC just fires once at the
        // first matching time and tags daily/weekdays for follow-up work.
        let notes = recurrence == .once ? nil : "Recurrence: \(recurrence.rawValue)"
        return await dispatchReminder(title: title, due: fireAt, notes: notes)
    }

    /// Dispatch a timer as an EKReminder with an attached EKAlarm at
    /// (now + N seconds). Same path as alarm — the iOS Reminders system
    /// owns the fire, not us. Persists across app kill.
    private static func dispatchTimerAsReminder(seconds: Int, label: String?) async -> DispatchOutcome {
        guard seconds >= 1 else { return .failed(reason: "timer needs positive seconds, got \(seconds)") }
        let fireAt = Date().addingTimeInterval(TimeInterval(seconds))
        let title = (label?.isEmpty == false ? label! : "Timer")
        return await dispatchReminder(title: title, due: fireAt, notes: nil)
    }

    /// Schedule an alarm as a local notification. iOS doesn't expose the
    /// system Clock app, so we use UNUserNotificationCenter — fires at the
    /// requested clock time with sound + time-sensitive interruption.
    /// Recurrence becomes the calendar trigger's `repeats: true` with the
    /// right `dateMatching` components.
    private static func dispatchAlarm(time: String, label: String?, recurrence: Recurrence) async -> DispatchOutcome {
        let granted = await requestNotificationAuth()
        if !granted { return .failed(reason: "Notification access denied") }
        let parts = time.split(separator: ":").map(String.init)
        guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]) else {
            return .failed(reason: "invalid time '\(time)'")
        }
        let content = UNMutableNotificationContent()
        content.title = label?.isEmpty == false ? label! : "Alarm"
        content.body = "Nooto alarm"
        content.sound = UNNotificationSound.defaultRingtone
        content.interruptionLevel = .timeSensitive

        var components = DateComponents()
        components.hour = hour
        components.minute = minute

        switch recurrence {
        case .daily:
            // Fires every day at HH:MM
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
            return await addRequest(content: content, trigger: trigger, prefix: "nooto-alarm-daily")
        case .weekdays:
            // Five separate triggers (Mon–Fri) since UNCalendarNotificationTrigger
            // can only match one weekday per request.
            for weekday in 2...6 {
                var c = components
                c.weekday = weekday
                let trigger = UNCalendarNotificationTrigger(dateMatching: c, repeats: true)
                let outcome = await addRequest(content: content, trigger: trigger, prefix: "nooto-alarm-wd\(weekday)")
                if case .failed = outcome { return outcome }
            }
            return .success
        case .once:
            // One-shot at the next occurrence of HH:MM (today if still in the
            // future, otherwise tomorrow). Using a non-repeating calendar
            // trigger and letting the system pick the next match.
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            return await addRequest(content: content, trigger: trigger, prefix: "nooto-alarm-once")
        }
    }

    /// Schedule a timer as a local notification firing in `seconds` from now.
    /// UNTimeIntervalNotificationTrigger has a 60s minimum for repeats but
    /// supports any positive interval ≥ 1s for one-shot.
    private static func dispatchTimer(seconds: Int, label: String?) async -> DispatchOutcome {
        let granted = await requestNotificationAuth()
        if !granted { return .failed(reason: "Notification access denied") }
        guard seconds >= 1 else { return .failed(reason: "timer needs positive seconds, got \(seconds)") }
        let content = UNMutableNotificationContent()
        content.title = label?.isEmpty == false ? label! : "Timer"
        content.body = "Time's up."
        content.sound = UNNotificationSound.default
        content.interruptionLevel = .timeSensitive
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: TimeInterval(seconds), repeats: false)
        return await addRequest(content: content, trigger: trigger, prefix: "nooto-timer")
    }

    private static func requestNotificationAuth() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional {
            return true
        }
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge, .timeSensitive])
            return granted
        } catch {
            return false
        }
    }

    private static func addRequest(content: UNNotificationContent, trigger: UNNotificationTrigger, prefix: String) async -> DispatchOutcome {
        let identifier = "\(prefix)-\(UUID().uuidString)"
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        do {
            try await UNUserNotificationCenter.current().add(request)
            return .success
        } catch {
            return .failed(reason: "Notification schedule failed: \(error.localizedDescription)")
        }
    }

    private static func dispatchEvent(title: String, start: Date, durationMinutes: Int, location: String?, notes: String?) async -> DispatchOutcome {
        let store = EKEventStore()
        do {
            let granted = try await store.requestFullAccessToEvents()
            guard granted else { return .failed(reason: "Calendar access denied") }
        } catch {
            return .failed(reason: "Calendar access error: \(error.localizedDescription)")
        }
        guard let calendar = store.defaultCalendarForNewEvents else {
            return .failed(reason: "No default calendar for new events")
        }
        let event = EKEvent(eventStore: store)
        event.title = title
        event.startDate = start
        event.endDate = start.addingTimeInterval(TimeInterval(durationMinutes * 60))
        event.location = location
        event.notes = notes
        event.calendar = calendar
        do {
            try store.save(event, span: .thisEvent)
            return .success
        } catch {
            return .failed(reason: "EventKit save failed: \(error.localizedDescription)")
        }
    }

    private static func dispatchReminder(title: String, due: Date?, notes: String?) async -> DispatchOutcome {
        let store = EKEventStore()
        do {
            let granted = try await store.requestFullAccessToReminders()
            guard granted else { return .failed(reason: "Reminders access denied") }
        } catch {
            return .failed(reason: "Reminders access error: \(error.localizedDescription)")
        }
        guard let calendar = store.defaultCalendarForNewReminders() else {
            return .failed(reason: "No default reminders list")
        }
        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        reminder.notes = notes
        reminder.calendar = calendar
        if let due {
            let components = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute],
                from: due
            )
            reminder.dueDateComponents = components
            reminder.addAlarm(EKAlarm(absoluteDate: due))
        }
        do {
            try store.save(reminder, commit: true)
            return .success
        } catch {
            return .failed(reason: "EKReminder save failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Helpers

    private static func loadInstructions() -> String {
        // Bundled at build time via `intent_prompt.txt` resource on the Runner target.
        if let url = Bundle.main.url(forResource: "intent_prompt", withExtension: "txt"),
           let data = try? String(contentsOf: url, encoding: .utf8) {
            return data
        }
        // Fallback baseline if the resource is missing for some reason.
        return """
        Parse the user's text into a Nooto intent.

        Choose:
        - set_alarm for clock-time wake or alarm requests.
        - start_timer for countdown requests like X minute timer, X min, pomodoro, for X minutes.
        - add_event for calendar items: meetings, appointments, lunch, standup, scheduling, "block N hours".
        - make_reminder for tasks and to-dos: "remind me to X", "todo X", "don't forget to X".
        - unknown for anything else.

        The user prompt starts with "Now: <weekday YYYY-MM-DD HH:mm>". Use that as the anchor when resolving relative dates. Always output absolute ISO 8601 local datetime for start and due. Default event duration is 60 minutes if unspecified.

        Fill only the fields that apply to the chosen kind; leave the others null. Don't invent location or notes — only set them if the user explicitly said them.
        """
    }

    private static func describeAvailability(_ reason: SystemLanguageModel.Availability.UnavailableReason) -> String {
        switch reason {
        case .deviceNotEligible:
            return "This device isn't Apple Intelligence-capable. Requires iPhone 15 Pro or later."
        case .appleIntelligenceNotEnabled:
            return "Apple Intelligence is off. Enable it in Settings → Apple Intelligence & Siri."
        case .modelNotReady:
            return "The on-device model is still downloading or warming up. Try again in a minute."
        @unknown default:
            return "Apple Intelligence isn't available."
        }
    }

    private static func intentKind(_ intent: NootoIntent) -> String {
        switch intent {
        case .setAlarm: return "set_alarm"
        case .startTimer: return "start_timer"
        case .addEvent: return "add_event"
        case .makeReminder: return "make_reminder"
        case .unknown: return "unknown"
        }
    }

    private static func prettyJSON(_ intent: NootoIntent) -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(intent), let s = String(data: data, encoding: .utf8) else {
            return "<encode-failed>"
        }
        return s
    }
}

// MARK: - Timeout helper

struct TimeoutError: Error, LocalizedError {
    var errorDescription: String? { "LLM call exceeded its time budget." }
}

@available(iOS 26.0, *)
func withTimeout<T: Sendable>(
    seconds: TimeInterval,
    operation: @Sendable @escaping () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw TimeoutError()
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}

@available(iOS 16.0, *)
private extension Duration {
    var milliseconds: Double {
        let (s, attoseconds) = components
        return Double(s) * 1_000 + Double(attoseconds) / 1_000_000_000_000_000
    }
}
