import Foundation

enum CanvasCalendarExport {
    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: ";", with: "\\;")
            .replacingOccurrences(of: ",", with: "\\,")
    }
    // RFC 5545 lines are folded by UTF-8 octets without splitting a character.
    private static func fold(_ line: String) -> String {
        var result = ""; var count = 0
        for character in line {
            let text = String(character); let size = text.utf8.count
            if count + size > 75 { result += "\r\n "; count = 1 }
            result += text; count += size
        }
        return result
    }
    static func make(_ items: [CanvasCandidate], now: Date = Date()) -> String {
        let format = DateFormatter(); format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = TimeZone(secondsFromGMT: 0); format.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        var lines = ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Daylist//Canvas Import//ZH", "CALSCALE:GREGORIAN"]
        for item in items {
            guard let day = item.day, let base = Day.date(day) else { continue }
            let stable = (item.source.assignmentIdentity ?? item.source.identities.first ?? item.id.uuidString)
                .data(using: .utf8)!.base64EncodedString().replacingOccurrences(of: "=", with: "")
            lines += ["BEGIN:VEVENT", "UID:" + stable + "@wodue.local", "DTSTAMP:" + format.string(from: now),
                "LAST-MODIFIED:" + format.string(from: item.source.notifiedAt ?? now),
                "SUMMARY:" + escape(item.title), "DESCRIPTION:" + escape("Canvas 截止时间；原文与最新发布时间见待办。\n" + item.original)]
            if let minute = item.minute,
               let start = Day.calendar.date(byAdding: .minute, value: minute, to: Day.calendar.startOfDay(for: base)) {
                lines += ["DTSTART:" + format.string(from: start), "DTEND:" + format.string(from: start.addingTimeInterval(60))]
                for offset in ["-PT24H", "-PT1H"] {
                    lines += ["BEGIN:VALARM", "TRIGGER:" + offset, "ACTION:DISPLAY", "DESCRIPTION:" + escape(item.title + (item.source.isDeadline ? " 即将截止" : " 即将开始")), "END:VALARM"]
                }
            } else {
                lines += ["DTSTART;VALUE=DATE:" + day.replacingOccurrences(of: "-", with: ""),
                    "DTEND;VALUE=DATE:" + Day.adding(1, to: day).replacingOccurrences(of: "-", with: "")]
            }
            if let link = item.link.flatMap(WebLink.safe) { lines.append("URL:" + link.absoluteString) }
            lines += ["TRANSP:TRANSPARENT", "END:VEVENT"]
        }
        lines.append("END:VCALENDAR")
        return lines.map(fold).joined(separator: "\r\n") + "\r\n"
    }
}
