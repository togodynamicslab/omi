import EventKit
import Flutter
import Foundation
import UIKit

/// EventKit-only dispatcher exposed to Dart on every iOS version.
///
/// Split out from `IntentBridge.swift` so the dispatch surface (Calendar,
/// Reminders, alarm-as-reminder, timer-as-reminder) is available even on
/// iOS versions that don't have Foundation Models (iOS 18 and earlier).
/// Dart-side cloud parser produces the structured intent fields, then
/// calls `dispatchStructured` here to actually fire the system action.
///
/// Method channel contract (`com.nooto.intent_dispatcher`):
///   dispatchStructured({
///       kind: String,                 // set_alarm | start_timer | add_event | make_reminder
///       time: String?,                // HH:MM 24h  (set_alarm)
///       seconds: Int?,                // (start_timer)
///       recurrence: String?,          // once | daily | weekdays (set_alarm)
///       label: String?,
///       title: String?,               // add_event | make_reminder
///       start: String?,               // ISO 8601 local (add_event)
///       durationMinutes: Int?,        // (add_event)
///       due: String?,                 // ISO 8601 local (make_reminder, optional)
///       location: String?,
///       notes: String?,
///   })
///   → { status: String, reason: String? }
///
/// Returns `status: "success" | "failed"` plus a reason on failure.
/// No-op'ing on unknown is the caller's job.
class IntentDispatchBridge {
    static let channelName = "com.nooto.intent_dispatcher"

    private let channel: FlutterMethodChannel

    init(messenger: FlutterBinaryMessenger) {
        channel = FlutterMethodChannel(name: IntentDispatchBridge.channelName, binaryMessenger: messenger)
        channel.setMethodCallHandler { [weak self] call, result in
            self?.handle(call, result: result)
        }
    }

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "dispatchStructured":
            guard let args = call.arguments as? [String: Any] else {
                result(FlutterError(code: "BAD_ARGS", message: "expected map", details: nil))
                return
            }
            Task { @MainActor in
                let outcome = await Self.dispatch(args)
                result([
                    "status": outcome.status,
                    "reason": outcome.reason as Any? ?? NSNull(),
                    "identifier": outcome.identifier as Any? ?? NSNull(),
                ])
            }
        case "existingReminderIdentifiers":
            // Reverse-check seam for the proactive-push service. Dart sends
            // a list of EKReminder calendarItemIdentifiers we previously
            // saved; we return the subset that still exist in the user's
            // Reminders database. Anything missing = user deleted in
            // Reminders, never re-push.
            guard let args = call.arguments as? [String: Any],
                  let ids = args["identifiers"] as? [String] else {
                result(FlutterError(code: "BAD_ARGS", message: "expected identifiers: [String]", details: nil))
                return
            }
            Task { @MainActor in
                let present = await Self.existingReminderIdentifiers(ids: ids)
                result(["present": present])
            }
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - Public dispatch entry point (also used by IntentBridge on iOS 26+)

    enum Outcome {
        case success(identifier: String? = nil)
        case failed(reason: String)

        var status: String {
            switch self {
            case .success: return "success"
            case .failed: return "failed"
            }
        }
        var reason: String? {
            if case let .failed(reason) = self { return reason }
            return nil
        }
        var identifier: String? {
            if case let .success(id) = self { return id }
            return nil
        }
    }

    @MainActor
    static func dispatch(_ args: [String: Any]) async -> Outcome {
        let kind = (args["kind"] as? String) ?? "unknown"
        switch kind {
        case "set_alarm":
            return await dispatchAlarmAsReminder(args: args)
        case "start_timer":
            // Timer scheduling moved to Dart side (flutter_local_notifications.
            // zonedSchedule) to sidestep iOS's third-party-app-can't-touch-
            // Clock-app constraint without requiring a user-installed Shortcut.
            // The native side just returns success; Dart schedules + persists.
            return .success(identifier: nil)
        case "add_event":
            return await dispatchEvent(args: args)
        case "make_reminder":
            return await dispatchReminder(args: args)
        case "unknown":
            return .failed(reason: "no-op for unknown intent")
        default:
            return .failed(reason: "unrecognized kind '\(kind)'")
        }
    }

    // MARK: - Per-kind helpers

    private static func dispatchAlarmAsReminder(args: [String: Any]) async -> Outcome {
        guard let time = args["time"] as? String else {
            return .failed(reason: "set_alarm missing time")
        }
        let parts = time.split(separator: ":").map(String.init)
        guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]) else {
            return .failed(reason: "invalid time '\(time)'")
        }
        let now = Date()
        var fireAt = Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: now) ?? now
        if fireAt <= now {
            fireAt = Calendar.current.date(byAdding: .day, value: 1, to: fireAt) ?? fireAt
        }
        let label = (args["label"] as? String).flatMap(nilIfEmpty) ?? "Alarm"
        let recurrence = (args["recurrence"] as? String).flatMap(nilIfEmpty) ?? "once"
        let notes = recurrence == "once" ? nil : "Recurrence: \(recurrence)"
        return await saveReminder(title: label, due: fireAt, notes: notes)
    }

    /// DEPRECATED — superseded by `dispatchTimerViaShortcut`. Kept around
    /// briefly so we can flip back if the Shortcut path proves unworkable.
    /// Safe to delete once the Shortcuts-based flow has been dogfooded.
    @available(*, deprecated, message: "Use dispatchTimerViaShortcut for real Clock-app timer")
    private static func dispatchTimerAsReminder(args: [String: Any]) async -> Outcome {
        guard let seconds = args["seconds"] as? Int, seconds >= 1 else {
            return .failed(reason: "timer needs positive seconds")
        }
        let label = (args["label"] as? String).flatMap(nilIfEmpty) ?? "Timer"
        let fireAt = Date().addingTimeInterval(TimeInterval(seconds))
        return await saveReminder(title: label, due: fireAt, notes: nil)
    }

    /// Dispatch a timer via the iOS Shortcuts URL scheme — the only public
    /// path to the Clock app's actual timer from a third-party app. Requires
    /// a user-installed Shortcut named `NootoStartTimer` that accepts text
    /// input ("<seconds>|<label>") and calls the Clock app's "Start Timer"
    /// action.
    ///
    /// First-run gotcha: `UIApplication.shared.open` returns success even
    /// when no Shortcut with that name exists (Shortcuts.app shows its
    /// own "shortcut not found" alert and our app sees success). The chat
    /// composer's first-run copy guides the user to install the Shortcut.
    @MainActor
    private static func dispatchTimerViaShortcut(args: [String: Any]) async -> Outcome {
        guard let seconds = args["seconds"] as? Int, seconds >= 1 else {
            return .failed(reason: "timer needs positive seconds")
        }
        let label = (args["label"] as? String).flatMap(nilIfEmpty) ?? ""
        let payload = "\(seconds)|\(label)"
        var c = URLComponents()
        c.scheme = "shortcuts"
        c.host = "run-shortcut"
        c.queryItems = [
            URLQueryItem(name: "name", value: "NootoStartTimer"),
            URLQueryItem(name: "input", value: "text"),
            URLQueryItem(name: "text", value: payload),
        ]
        guard let url = c.url else {
            return .failed(reason: "could not build NootoStartTimer URL")
        }
        let ok = await UIApplication.shared.open(url, options: [:])
        return ok ? .success(identifier: nil) : .failed(reason: "system refused to open \(url.absoluteString)")
    }

    private static func dispatchEvent(args: [String: Any]) async -> Outcome {
        guard let title = (args["title"] as? String).flatMap(nilIfEmpty) else {
            return .failed(reason: "add_event missing title")
        }
        guard let startRaw = args["start"] as? String, let start = parseISO8601(startRaw) else {
            return .failed(reason: "add_event missing or unparseable start")
        }
        let duration = max(5, (args["durationMinutes"] as? Int) ?? 60)
        let location = (args["location"] as? String).flatMap(nilIfEmpty)
        let notes = (args["notes"] as? String).flatMap(nilIfEmpty)

        let store = EKEventStore()
        let granted = await requestCalendarAccess(store: store)
        guard granted else { return .failed(reason: "Calendar access denied") }
        guard let calendar = store.defaultCalendarForNewEvents else {
            return .failed(reason: "No default calendar for new events")
        }
        let event = EKEvent(eventStore: store)
        event.title = title
        event.startDate = start
        event.endDate = start.addingTimeInterval(TimeInterval(duration * 60))
        event.location = location
        event.notes = notes
        event.calendar = calendar
        do {
            try store.save(event, span: .thisEvent)
            return .success(identifier: event.eventIdentifier)
        } catch {
            return .failed(reason: "EventKit save failed: \(error.localizedDescription)")
        }
    }

    private static func dispatchReminder(args: [String: Any]) async -> Outcome {
        guard let title = (args["title"] as? String).flatMap(nilIfEmpty) else {
            return .failed(reason: "make_reminder missing title")
        }
        let due: Date? = (args["due"] as? String).flatMap { parseISO8601($0) }
        let notes = (args["notes"] as? String).flatMap(nilIfEmpty)
        return await saveReminder(title: title, due: due, notes: notes)
    }

    // MARK: - Reverse-check (proactive-push deletion detection)

    /// Returns the subset of [ids] that still have an EKReminder in the
    /// user's Reminders database. Used by [ProactivePushService.runReverseCheck]
    /// to detect "user deleted the reminder" and never re-push that item.
    ///
    /// Uses `fetchReminders(matching:)` with a default-predicate, then filters
    /// in memory. The list is bounded by [ProactivePushPrefs.dailyBudget]
    /// over a few days, so we're not loading thousands of rows here. Doing
    /// it in one fetch avoids the n-API-call problem that
    /// `calendarItem(withIdentifier:)` would have for a list of N ids.
    @MainActor
    static func existingReminderIdentifiers(ids: [String]) async -> [String] {
        guard !ids.isEmpty else { return [] }
        let store = EKEventStore()
        let granted = await requestRemindersAccess(store: store)
        guard granted else { return ids }  // No access → conservative: pretend all still exist.
        let wanted = Set(ids)
        let predicate = store.predicateForReminders(in: nil)
        let reminders: [EKReminder] = await withCheckedContinuation { cont in
            store.fetchReminders(matching: predicate) { fetched in
                cont.resume(returning: fetched ?? [])
            }
        }
        var present: [String] = []
        for reminder in reminders {
            let identifier = reminder.calendarItemIdentifier
            if wanted.contains(identifier) {
                present.append(identifier)
            }
        }
        return present
    }

    // MARK: - EKReminder save helper (used by alarm + timer + reminder)

    /// Name of the dedicated Reminders list we file Nooto-pushed items into.
    /// Lets the user see "what did Nooto put here?" at a glance, and lets
    /// them nuke the whole list in one swipe (reverse-check will catch the
    /// deletion and mark every tracked row as `userDeleted`).
    private static let nootoRemindersListTitle = "Nooto"

    /// Returns the "Nooto" Reminders list, creating it on first use. Source
    /// is chosen to match the user's default reminders list (so it lives in
    /// iCloud if they sync, local otherwise). Returns nil only if both
    /// lookup and creation fail — caller falls back to the default list.
    private static func nootoRemindersCalendar(in store: EKEventStore) -> EKCalendar? {
        if let existing = store.calendars(for: .reminder).first(where: { $0.title == nootoRemindersListTitle }) {
            return existing
        }
        let cal = EKCalendar(for: .reminder, eventStore: store)
        cal.title = nootoRemindersListTitle
        let source = store.defaultCalendarForNewReminders()?.source
            ?? store.sources.first(where: { $0.sourceType == .calDAV && $0.title.lowercased().contains("icloud") })
            ?? store.sources.first(where: { $0.sourceType == .local })
            ?? store.sources.first
        guard let source else { return nil }
        cal.source = source
        do {
            try store.saveCalendar(cal, commit: true)
            return cal
        } catch {
            return nil
        }
    }

    private static func saveReminder(title: String, due: Date?, notes: String?) async -> Outcome {
        let store = EKEventStore()
        let granted = await requestRemindersAccess(store: store)
        guard granted else { return .failed(reason: "Reminders access denied") }
        guard let calendar = nootoRemindersCalendar(in: store) ?? store.defaultCalendarForNewReminders() else {
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
            return .success(identifier: reminder.calendarItemIdentifier)
        } catch {
            return .failed(reason: "EKReminder save failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Permission helpers (handle iOS 13–16 vs iOS 17+ split)

    /// Request full calendar access. Uses iOS 17's async API on capable
    /// devices, falls back to the iOS 16 callback API for older devices.
    private static func requestCalendarAccess(store: EKEventStore) async -> Bool {
        if #available(iOS 17.0, *) {
            do {
                return try await store.requestFullAccessToEvents()
            } catch {
                return false
            }
        } else {
            return await withCheckedContinuation { cont in
                store.requestAccess(to: .event) { granted, _ in
                    cont.resume(returning: granted)
                }
            }
        }
    }

    /// Same shape as `requestCalendarAccess` but for reminders.
    private static func requestRemindersAccess(store: EKEventStore) async -> Bool {
        if #available(iOS 17.0, *) {
            do {
                return try await store.requestFullAccessToReminders()
            } catch {
                return false
            }
        } else {
            return await withCheckedContinuation { cont in
                store.requestAccess(to: .reminder) { granted, _ in
                    cont.resume(returning: granted)
                }
            }
        }
    }

    // MARK: - Helpers

    private static func parseISO8601(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let withTZ = ISO8601DateFormatter()
        withTZ.formatOptions = [.withInternetDateTime]
        if let d = withTZ.date(from: trimmed) { return d }
        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        local.timeZone = TimeZone.current
        for fmt in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm"] {
            local.dateFormat = fmt
            if let d = local.date(from: trimmed) { return d }
        }
        return nil
    }
}

/// String? helper: returns nil if the trimmed string is empty, otherwise the trimmed string.
private func nilIfEmpty(_ s: String) -> String? {
    let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}
