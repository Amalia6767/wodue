import Foundation

struct ParsedEvent {
    var task: Todo
    var warnings: [String]
    var foundDate: Bool
}

enum WebLink {
    static func safe(_ value: String?) -> URL? {
        guard let value, let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { return nil }
        return url
    }
    static func first(in text: String) -> URL? {
        let limited = String(text.prefix(100_000))
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let links = detector?.matches(in: limited, range: NSRange(limited.startIndex..., in: limited)).compactMap { safe($0.url?.absoluteString) } ?? []
        return links.first { $0.host?.contains("zoom") == true || $0.host?.contains("teams") == true || $0.host?.contains("meet.google") == true } ?? links.first
    }
}

enum EventParser {
    private static func matches(_ pattern: String, _ text: String) -> [[String]] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { match in
            (0..<match.numberOfRanges).map { i in
                let range = match.range(at: i)
                return range.location == NSNotFound ? "" : ns.substring(with: range)
            }
        }
    }
    private static func replacing(_ pattern: String, in text: String, with replacement: String = "") -> String {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return text }
        return re.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: replacement)
    }
    static func parse(_ raw: String, reference: Date = Date()) -> ParsedEvent {
        let text = String(raw.prefix(50_000)).replacingOccurrences(of: "\u{00a0}", with: " ")
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        var warnings: [String] = []
        if raw.count > 50_000 { warnings.append("内容较长，仅识别前 50,000 字。") }
        var day: String? = nil
        let currentYear = Day.calendar.component(.year, from: reference)
        var candidates = Set<String>()
        func addDate(_ year: Int, _ month: Int, _ date: Int) {
            let key = String(format: "%04d-%02d-%02d", year, month, date)
            if Day.date(key) != nil { candidates.insert(key); if day == nil { day = key } }
        }
        for m in matches(#"\b(20\d{2})[-/.年]\s*(\d{1,2})[-/.月]\s*(\d{1,2})(?:日|号)?"#, text) {
            if let y = Int(m[1]), let mo = Int(m[2]), let d = Int(m[3]) { addDate(y, mo, d) }
        }
        let months = ["january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december"]
        let monthPattern = "(Jan(?:uary)?|Feb(?:ruary)?|Mar(?:ch)?|Apr(?:il)?|May|Jun(?:e)?|Jul(?:y)?|Aug(?:ust)?|Sep(?:tember)?|Oct(?:ober)?|Nov(?:ember)?|Dec(?:ember)?)"
        func monthNumber(_ value: String) -> Int? { months.firstIndex { $0.hasPrefix(value.lowercased()) }.map { $0 + 1 } }
        for m in matches(#"\b(\d{1,2})(?:st|nd|rd|th)?\s+"# + monthPattern + #"(?:\s*,?\s*(20\d{2}))?\b"#, text) {
            if let d = Int(m[1]), let mo = monthNumber(m[2]) { addDate(Int(m[3]) ?? currentYear, mo, d) }
        }
        for m in matches(#"\b"# + monthPattern + #"\s+(\d{1,2})(?:st|nd|rd|th)?(?:\s*,?\s*(20\d{2}))?\b"#, text) {
            if let mo = monthNumber(m[1]), let d = Int(m[2]) { addDate(Int(m[3]) ?? currentYear, mo, d) }
        }
        if day == nil {
            for m in matches(#"(?<!\d)(\d{1,2})\s*月\s*(\d{1,2})\s*[日号]?"#, text) {
                if let mo = Int(m[1]), let d = Int(m[2]) { addDate(currentYear, mo, d) }
            }
        }
        if day == nil {
            let referenceDay = Day.key(reference)
            if text.localizedCaseInsensitiveContains("后天") { day = Day.adding(2, to: referenceDay) }
            else if text.localizedCaseInsensitiveContains("明天") || text.range(of: #"\btomorrow\b"#, options: [.regularExpression, .caseInsensitive]) != nil { day = Day.adding(1, to: referenceDay) }
            else if text.contains("今天") || text.range(of: #"\btoday\b"#, options: [.regularExpression, .caseInsensitive]) != nil { day = referenceDay }
        }
        // Ambiguous slash dates remain visible for the user to decide instead of
        // silently choosing between month/day and day/month conventions.
        if day == nil, !matches(#"\b\d{1,2}/\d{1,2}(?:/\d{2,4})?\b"#, text).isEmpty {
            warnings.append("发现斜杠日期，月 / 日顺序不明确，请手动确认日期。")
        }
        if candidates.count > 1 { warnings.append("发现多个日期，先列出第一个；请确认要安排的是哪一天。") }
        let foundDate = day != nil
        if !foundDate { warnings.append("没有找到明确日期，下面暂用今天，请修改或确认。") }

        let timeLines = lines.filter { !$0.lowercased().hasPrefix("http") &&
            $0.range(of: #"^(?:webinar|meeting|passcode|password|会议号|密码)\b"#, options: [.regularExpression, .caseInsensitive]) == nil }
        let labeled = timeLines.first { $0.range(of: #"^(?:time|时间|時间|時閒|时段)\s*[:：]"#, options: [.regularExpression, .caseInsensitive]) != nil }
        let timeText = labeled ?? timeLines.joined(separator: "\n")
        var start: Int? = nil
        var end: Int? = nil
        func clock(_ hour: String, _ minute: String, _ mark: String, context: String) -> Int? {
            guard var h = Int(hour), let m = Int(minute.isEmpty ? "0" : minute), (0...59).contains(m) else { return nil }
            let marker = mark.lowercased().replacingOccurrences(of: ".", with: "")
            let pm = marker == "pm" || (marker.isEmpty && context.range(of: "下午|晚上|中午", options: .regularExpression) != nil)
            let am = marker == "am" || (marker.isEmpty && context.range(of: "上午|早上|凌晨", options: .regularExpression) != nil)
            if pm || am {
                guard (1...12).contains(h) || (am && h == 0) else { return nil }
                if h == 12 { h = 0 }
                if pm { h += 12 }
            }
            guard (0...23).contains(h) else { return nil }
            return h * 60 + m
        }
        let rangePattern = #"(?<![\d/.-])(\d{1,2})(?:[:：](\d{2}))?\s*(a\.?m\.?|p\.?m\.?)?\s*(?:–|—|－|-|~|～|至|到)\s*(\d{1,2})(?:[:：](\d{2}))?\s*(a\.?m\.?|p\.?m\.?)?(?![\d/.-])"#
        let ranges = matches(rangePattern, timeText).filter { m in
            // An unlabeled 28-30 or an ISO date is not a time range.
            !m[2].isEmpty || !m[5].isEmpty || !m[3].isEmpty || !m[6].isEmpty || labeled != nil || timeText.range(of: "下午|上午|晚上|早上", options: .regularExpression) != nil
        }
        if let m = ranges.first {
            let firstMark = m[3].isEmpty ? m[6] : m[3]
            let secondMark = m[6].isEmpty ? m[3] : m[6]
            start = clock(m[1], m[2], firstMark, context: timeText)
            end = clock(m[4], m[5], secondMark, context: timeText)
            if ranges.count > 1 { warnings.append("发现多个时间段，先使用第一个，请确认。") }
        } else if let m = matches(#"(?<![\d/])(\d{1,2})[:：](\d{2})\s*(a\.?m\.?|p\.?m\.?)?(?!\d)"#, timeText).first {
            start = clock(m[1], m[2], m[3], context: timeText)
        } else if let m = matches(#"(\d{1,2})\s*[点時时](?:(\d{1,2})分?|半)?"#, timeText).first {
            start = clock(m[1], m[0].contains("半") ? "30" : m[2], "", context: timeText)
        } else if let m = matches(#"\b(\d{1,2})\s*(am|pm)\b"#, timeText).first {
            start = clock(m[1], "", m[2], context: timeText)
        }
        if let s = start, let e = end, e <= s {
            end = nil; warnings.append("结束时间早于开始时间，可能跨天；请确认并按天拆分。")
        }
        if start == nil { warnings.append("没有找到明确时间，将作为未定时间的事项。") }

        var timeZone: TimeZone? = nil
        if text.range(of: #"\bHKT\b|Hong Kong (?:Time|Standard)|香港时间|北京时间"#, options: [.regularExpression, .caseInsensitive]) != nil {
            timeZone = TimeZone(identifier: "Asia/Hong_Kong")
        } else if let zone = matches(#"\b(?:UTC|GMT)\s*([+-])\s*(\d{1,2})(?::?(\d{2}))?\b"#, text).first,
                  let h = Int(zone[2]), h <= 14 {
            let minute = Int(zone[3]) ?? 0
            if minute < 60 { timeZone = TimeZone(secondsFromGMT: (zone[1] == "-" ? -1 : 1) * (h * 3600 + minute * 60)) }
        } else if text.range(of: #"\bUTC\b|\bGMT\b"#, options: [.regularExpression, .caseInsensitive]) != nil {
            timeZone = TimeZone(secondsFromGMT: 0)
        } else if text.range(of: #"\b(?:EST|EDT|PST|PDT|CST|CEST|CET|BST)\b"#, options: [.regularExpression, .caseInsensitive]) != nil {
            warnings.append("发现地区时区缩写，请确认是否需要换算成本机时间。")
        }
        var resolvedDay = day ?? Day.key(reference)
        if let zone = timeZone, let minute = start, let d = Day.date(resolvedDay) {
            var sourceCalendar = Day.calendar
            sourceCalendar.timeZone = zone
            let parts = Day.calendar.dateComponents([.year, .month, .day], from: d)
            var startParts = parts; startParts.hour = minute / 60; startParts.minute = minute % 60
            if let sourceDate = sourceCalendar.date(from: startParts) {
                resolvedDay = Day.key(sourceDate)
                start = Day.calendar.component(.hour, from: sourceDate) * 60 + Day.calendar.component(.minute, from: sourceDate)
                if let e = end {
                    var endParts = parts; endParts.hour = e / 60; endParts.minute = e % 60
                    if let endDate = sourceCalendar.date(from: endParts), Day.key(endDate) == resolvedDay {
                        end = Day.calendar.component(.hour, from: endDate) * 60 + Day.calendar.component(.minute, from: endDate)
                    } else { end = nil; warnings.append("换算后时间跨天，结束时间请手动确认。") }
                }
                warnings.append("已按邮件标注的时区换算为本机时间。")
            }
        } else if timeZone == nil && start != nil {
            warnings.append("未标明可换算的时区，按本机时间（\(TimeZone.current.identifier)）安排。")
        }

        let link = WebLink.first(in: text)
        var title = ""
        if let labeledTitle = lines.first(where: { $0.range(of: #"^(?:subject|主题|主旨|event|活动名称|title)\s*[:：]"#, options: [.regularExpression, .caseInsensitive]) != nil }) {
            title = replacing(#"^(?:subject|主题|主旨|event|活动名称|title)\s*[:：]\s*"#, in: labeledTitle)
        } else {
            let ranked = lines.enumerated().compactMap { (i, line) -> (String, Int, Int)? in
                if line.count < 3 || line.count > 250 || line.hasPrefix("http") { return nil }
                if line.range(of: #"^(?:thank|dear|hi\b|hello|best regards|regards|we look|please|join from|language|date|time|webinar id|meeting id|passcode|password|日期|时间|语言|会议号|密码|谢谢|此致)"#, options: [.regularExpression, .caseInsensitive]) != nil { return nil }
                if line.range(of: #"^\d[\d\s:：/.,()年月日-]*$"#, options: .regularExpression) != nil { return nil }
                var score = line.count < 130 ? 3 : 0
                if line.range(of: "information session|info session|webinar|workshop|meeting|lecture|讲座|会议|说明会|讨论|汇报", options: [.regularExpression, .caseInsensitive]) != nil { score += 6 }
                if line.unicodeScalars.first?.properties.isEmojiPresentation == true { score += 4 }
                if line.hasSuffix(".") { score -= 4 }
                return (line, score, i)
            }.sorted { $0.1 == $1.1 ? $0.2 < $1.2 : $0.1 > $1.1 }
            title = ranked.first?.0 ?? "从粘贴内容添加的事项"
        }
        title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        while let first = title.unicodeScalars.first, first.properties.isEmojiPresentation || first.value == 0xFE0F || [0x2022, 0x2D, 0x200D].contains(first.value) {
            title = String(title.unicodeScalars.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if title == "从粘贴内容添加的事项" { warnings.append("标题不够明确，请补充事项名称。") }
        let task = Todo(title: String(title.prefix(2000)), day: resolvedDay, startMinute: start, endMinute: end,
                        notes: text.trimmingCharacters(in: .whitespacesAndNewlines), link: link?.absoluteString,
                        kind: start != nil && end != nil ? .event : .task)
        return ParsedEvent(task: task, warnings: warnings, foundDate: foundDate)
    }
}
