import Foundation
import FoundationModels

/// Schema for the on-device intent parser.
/// Ported from app-v2/native-poc/ios/NootoIntentPoc/NootoIntent.swift after the
/// PoC cleared its end-to-end run on iOS 26.2 simulator (see the design doc
/// at ~/.gstack/projects/togodynamicslab-omi/matheusoliviera-main-design-poc-on-device-intent-*.md).
///
/// Three real dispatch surfaces today:
///   - set_alarm     → Shortcuts URL → user-created NootoSetAlarm shortcut
///   - start_timer   → Shortcuts URL → user-created NootoStartTimer shortcut
///   - add_event     → EventKit EKEvent.save (public API, no setup)
///   - make_reminder → EventKit EKReminder.save (public API, no setup)
///   - unknown       → no-op, surface reason in the UI

enum Recurrence: String, Codable, Sendable, CaseIterable {
    case once
    case daily
    case weekdays
}

enum NootoIntent: Sendable, Equatable {
    case setAlarm(time: String, label: String?, recurrence: Recurrence)
    case startTimer(seconds: Int, label: String?)
    case addEvent(title: String, start: Date, durationMinutes: Int, location: String?, notes: String?)
    case makeReminder(title: String, due: Date?, notes: String?)
    case unknown(reason: String)
}

/// What the LLM produces. Flat shape so the @Generable macro stays straightforward.
/// We narrow it into the strict NootoIntent enum below.
/// iOS 26+ only — Foundation Models is unavailable on earlier OS versions.
@available(iOS 26.0, *)
@Generable
struct LLMIntentDraft: Equatable, Sendable {
    @Guide(description: "set_alarm, start_timer, add_event, make_reminder, or unknown")
    var kind: String

    @Guide(description: "alarm clock time, 24-hour HH:MM")
    var time: String?

    @Guide(description: "once, daily, or weekdays")
    var recurrence: String?

    /// Shared between start_timer (-> seconds) and add_event (-> minutes).
    /// The model gives us the user's number ("25 minute timer" -> 25); we
    /// do the unit conversion in Swift to avoid arithmetic hallucinations.
    @Guide(description: "the numeric duration the user said for timer or event")
    var amount: Int?

    @Guide(description: "seconds, minutes, or hours")
    var unit: String?

    @Guide(description: "the short name of the event or reminder task. Required when kind is add_event or make_reminder. Examples: for 'meeting with Sarah tomorrow at 3pm' use 'meeting with Sarah'. For 'lunch at noon' use 'lunch'. For 'remind me to buy milk' use 'buy milk'. For 'remind me to call mom at 5pm' use 'call mom'. For 'todo review PR for John' use 'review PR for John'. Strip the 'remind me to' / 'todo' / 'don't forget to' prefix. Never leave this blank.")
    var title: String?

    @Guide(description: "event start as ISO 8601 local datetime like 2026-05-17T15:00:00")
    var start: String?

    @Guide(description: "optional due date and time for make_reminder, as ISO 8601 local datetime. Null if the user didn't specify when.")
    var due: String?

    @Guide(description: "optional event location. Only set if the user explicitly said one.")
    var location: String?

    @Guide(description: "optional event or reminder notes. Only set if the user explicitly said something to add as notes.")
    var notes: String?

    @Guide(description: "short label naming what the alarm or timer is for")
    var label: String?

    @Guide(description: "short reason this input is unknown")
    var reason: String?
}

@available(iOS 26.0, *)
extension NootoIntent {
    /// Validate the LLM's flat draft into the strict domain enum.
    /// Returns .unknown(...) for any malformed combination.
    static func from(draft: LLMIntentDraft) -> NootoIntent {
        switch draft.kind {
        case "set_alarm":
            guard let raw = draft.time, let time = normalizeTime(raw) else {
                return .unknown(reason: "set_alarm missing or invalid time '\(draft.time ?? "")'")
            }
            let recurrence = Recurrence(rawValue: (draft.recurrence ?? "once").lowercased()) ?? .once
            let label = draft.label?.trimmingCharacters(in: .whitespacesAndNewlines)
            return .setAlarm(time: time, label: (label?.isEmpty == false) ? label : nil, recurrence: recurrence)

        case "start_timer":
            guard let amount = draft.amount, amount > 0 else {
                return .unknown(reason: "start_timer requires positive amount, got \(draft.amount ?? -1)")
            }
            let unit = (draft.unit ?? "seconds").lowercased()
            let seconds: Int
            switch unit {
            case "second", "seconds", "sec", "secs", "s":
                seconds = amount
            case "minute", "minutes", "min", "mins", "m":
                seconds = amount * 60
            case "hour", "hours", "hr", "hrs", "h":
                seconds = amount * 3600
            default:
                return .unknown(reason: "start_timer has unrecognized unit '\(unit)'")
            }
            let label = draft.label?.trimmingCharacters(in: .whitespacesAndNewlines)
            return .startTimer(seconds: seconds, label: (label?.isEmpty == false) ? label : nil)

        case "add_event":
            guard let rawTitle = draft.title?.trimmingCharacters(in: .whitespacesAndNewlines), !rawTitle.isEmpty else {
                return .unknown(reason: "add_event missing title")
            }
            guard let startRaw = draft.start, let start = parseISO8601(startRaw) else {
                return .unknown(reason: "add_event missing or unparseable start '\(draft.start ?? "")'")
            }
            let duration: Int
            if let amount = draft.amount, amount > 0 {
                let unit = (draft.unit ?? "minutes").lowercased()
                switch unit {
                case "minute", "minutes", "min", "mins", "m":
                    duration = amount
                case "hour", "hours", "hr", "hrs", "h":
                    duration = amount * 60
                case "second", "seconds", "sec", "secs", "s":
                    duration = max(1, amount / 60)
                default:
                    duration = 60
                }
            } else {
                duration = 60
            }
            let loc = draft.location?.trimmingCharacters(in: .whitespacesAndNewlines)
            let notes = draft.notes?.trimmingCharacters(in: .whitespacesAndNewlines)
            return .addEvent(
                title: rawTitle,
                start: start,
                durationMinutes: max(5, duration),
                location: (loc?.isEmpty == false) ? loc : nil,
                notes: (notes?.isEmpty == false) ? notes : nil
            )

        case "make_reminder":
            guard let rawTitle = draft.title?.trimmingCharacters(in: .whitespacesAndNewlines), !rawTitle.isEmpty else {
                return .unknown(reason: "make_reminder missing title")
            }
            let due: Date? = draft.due.flatMap { parseISO8601($0) }
            let notes = draft.notes?.trimmingCharacters(in: .whitespacesAndNewlines)
            return .makeReminder(
                title: rawTitle,
                due: due,
                notes: (notes?.isEmpty == false) ? notes : nil
            )

        case "unknown":
            return .unknown(reason: draft.reason ?? "unspecified")

        default:
            return .unknown(reason: "unrecognized intent '\(draft.kind)'")
        }
    }

    /// Normalize a clock time to HH:MM 24-hour. Returns nil if invalid.
    private static func normalizeTime(_ raw: String) -> String? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = s.split(separator: ":").map(String.init)
        guard parts.count == 2,
              let h = Int(parts[0]), (0...23).contains(h),
              let m = Int(parts[1]), (0...59).contains(m)
        else { return nil }
        return String(format: "%02d:%02d", h, m)
    }

    /// Parse an ISO 8601 local datetime like "2026-05-17T15:00:00". Returns nil on malformed input.
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

// MARK: - JSON shape for the Dart bridge

extension NootoIntent: Codable {
    private enum Kind: String, Codable {
        case setAlarm = "set_alarm"
        case startTimer = "start_timer"
        case addEvent = "add_event"
        case makeReminder = "make_reminder"
        case unknown
    }
    private enum CodingKeys: String, CodingKey {
        case kind, time, label, recurrence, seconds, reason
        case title, start, durationMinutes = "duration_minutes", location, notes, due
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .setAlarm(time, label, recurrence):
            try c.encode(Kind.setAlarm, forKey: .kind)
            try c.encode(time, forKey: .time)
            try c.encodeIfPresent(label, forKey: .label)
            try c.encode(recurrence, forKey: .recurrence)
        case let .startTimer(seconds, label):
            try c.encode(Kind.startTimer, forKey: .kind)
            try c.encode(seconds, forKey: .seconds)
            try c.encodeIfPresent(label, forKey: .label)
        case let .addEvent(title, start, durationMinutes, location, notes):
            try c.encode(Kind.addEvent, forKey: .kind)
            try c.encode(title, forKey: .title)
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime]
            try c.encode(iso.string(from: start), forKey: .start)
            try c.encode(durationMinutes, forKey: .durationMinutes)
            try c.encodeIfPresent(location, forKey: .location)
            try c.encodeIfPresent(notes, forKey: .notes)
        case let .makeReminder(title, due, notes):
            try c.encode(Kind.makeReminder, forKey: .kind)
            try c.encode(title, forKey: .title)
            if let due {
                let iso = ISO8601DateFormatter()
                iso.formatOptions = [.withInternetDateTime]
                try c.encode(iso.string(from: due), forKey: .due)
            }
            try c.encodeIfPresent(notes, forKey: .notes)
        case let .unknown(reason):
            try c.encode(Kind.unknown, forKey: .kind)
            try c.encode(reason, forKey: .reason)
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(Kind.self, forKey: .kind)
        switch kind {
        case .setAlarm:
            self = .setAlarm(
                time: try c.decode(String.self, forKey: .time),
                label: try c.decodeIfPresent(String.self, forKey: .label),
                recurrence: try c.decode(Recurrence.self, forKey: .recurrence)
            )
        case .startTimer:
            self = .startTimer(
                seconds: try c.decode(Int.self, forKey: .seconds),
                label: try c.decodeIfPresent(String.self, forKey: .label)
            )
        case .addEvent:
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime]
            let startStr = try c.decode(String.self, forKey: .start)
            guard let start = iso.date(from: startStr) else {
                throw DecodingError.dataCorruptedError(forKey: .start, in: c, debugDescription: "bad ISO 8601 date")
            }
            self = .addEvent(
                title: try c.decode(String.self, forKey: .title),
                start: start,
                durationMinutes: try c.decode(Int.self, forKey: .durationMinutes),
                location: try c.decodeIfPresent(String.self, forKey: .location),
                notes: try c.decodeIfPresent(String.self, forKey: .notes)
            )
        case .makeReminder:
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime]
            let due: Date? = try c.decodeIfPresent(String.self, forKey: .due).flatMap { iso.date(from: $0) }
            self = .makeReminder(
                title: try c.decode(String.self, forKey: .title),
                due: due,
                notes: try c.decodeIfPresent(String.self, forKey: .notes)
            )
        case .unknown:
            self = .unknown(reason: try c.decode(String.self, forKey: .reason))
        }
    }
}
