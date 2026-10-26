import Foundation

struct CanvasReference: Codable, Equatable {
    var identities: [String]
    var assignmentIdentity: String?
    var notifiedAt: Date?
    var noticeURL: String?
    var isDeadline: Bool
}

enum CanvasDisposition: String {
    case add = "新增", update = "更新原任务", unchanged = "已存在", older = "旧通知，已忽略"
    case unknownOrder = "通知先后不明", conflict = "同一时间有冲突", needsDate = "待确认日期"
}

struct CanvasCandidate: Identifiable, Equatable {
    var id = UUID()
    var title: String
    var day: String?
    var minute: Int?
    var source: CanvasReference
    var link: String?
    var original: String
    var warnings: [String] = []
    var informational = false
    var closed = false
    var past = false
    var selected = false
    var mergedCount = 1
    var requiresConfirmation = false

    var task: Todo? {
        guard let day else { return nil }
        var note = "来源：Canvas\n"
        if let posted = source.notifiedAt {
            let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN"); f.dateFormat = "yyyy-MM-dd HH:mm"
            note += "通知发布：" + f.string(from: posted) + "\n"
        }
        if let url = source.noticeURL { note += "通知原文：" + url + "\n" }
        note += "\n" + original
        return Todo(title: String(title.prefix(2000)), day: day, startMinute: minute,
            notes: String(note.prefix(100_000)), link: link, canvasSource: source)
    }
}

enum CanvasParser {
    private struct Block { var title: String; var url: String?; var body: String; var context: String }
    private static func matches(_ pattern: String, _ text: String) -> [[String]] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { m in
            (0..<m.numberOfRanges).map { m.range(at: $0).location == NSNotFound ? "" : ns.substring(with: m.range(at: $0)) }
        }
    }
    private static func replace(_ pattern: String, _ text: String, _ replacement: String = "") -> String {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return text }
        return re.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: replacement)
    }
    static func clean(_ text: String) -> String {
        var s = text.replacingOccurrences(of: "\u{00a0}", with: " ")
        for (a, b) in [("&#x20;", " "), ("&#32;", " "), ("&nbsp;", " "), ("&amp;", "&"), ("&quot;", "\""), ("&#39;", "'"), ("&lt;", "<"), ("&gt;", ">"), ("**", ""), ("__", "")] {
            s = s.replacingOccurrences(of: a, with: b)
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func textFromHTML(_ html: String) -> String {
        var s = replace(#"(?is)<(?:script|style)\b[^>]*>.*?</(?:script|style)>"#, html)
        s = replace(#"(?is)<a\b[^>]*href=["'](https?://[^"']+)["'][^>]*>(.*?)</a>"#, s, "[$2]($1)")
        s = replace(#"(?is)</?(?:tr|p|div|li|h[1-6])\b[^>]*>|<br\s*/?>"#, s, "\n")
        s = replace(#"(?is)</t[dh]>"#, s, " | ")
        s = replace(#"(?is)<[^>]+>"#, s)
        return clean(s)
    }
    static func looksLike(_ text: String) -> Bool {
        text.range(of: #"/courses/\d+/(?:assignments|announcements)/\d+|assignment due date changed|upcoming assignments|assignment notifications|[A-Z]{2,8}\s?\d{3,4}"#, options: [.regularExpression, .caseInsensitive]) != nil
    }
    static func assignmentIdentity(_ url: String) -> String? {
        guard let value = WebLink.safe(url), let host = value.host?.lowercased(),
              let m = matches(#"^/courses/(\d+)/assignments/(\d+)(?:/|$)"#, value.path).first else { return nil }
        return host + "/courses/" + m[1] + "/assignments/" + m[2]
    }
    private static func blocks(_ text: String) -> [Block] {
        let re = try! NSRegularExpression(pattern: #"\[([^\]]+)\]\((https?://[^\s)]+/courses/\d+/(?:assignments|announcements)/\d+[^\s)]*)\)"#, options: [.caseInsensitive])
        let ns = text as NSString
        let links = re.matches(in: text, range: NSRange(location: 0, length: ns.length))
        if !links.isEmpty {
            return links.enumerated().map { i, m in
                let end = i + 1 < links.count ? links[i + 1].range.location : ns.length
                let tailStart = NSMaxRange(m.range)
                return Block(title: clean(ns.substring(with: m.range(at: 1))), url: clean(ns.substring(with: m.range(at: 2))),
                    body: clean(ns.substring(with: NSRange(location: tailStart, length: end - tailStart))),
                    context: ns.substring(to: m.range.location))
            }
        }
        // Browser plain-text copies lose anchors; retain the title and adjacent metadata.
        let lines = text.components(separatedBy: .newlines).map(clean).filter { !$0.isEmpty }
        var result: [Block] = []
        var title = ""; var body: [String] = []; var context = ""
        func flush() {
            guard !title.isEmpty else { return }
            let joined = body.joined(separator: "\n")
            let url = matches(#"https?://[^\s]+/courses/\d+/(?:assignments|announcements)/\d+"#, joined).first?.first
            result.append(Block(title: title, url: url, body: joined, context: context))
        }
        for line in lines {
            if line.range(of: #"^(?:upcoming assignments|past assignments|assignment notifications|announcement details|assignment details|recent activity|[A-Z]{2,8}\s?\d{3,4})\b"#, options: [.regularExpression, .caseInsensitive]) != nil {
                flush(); title = ""; body = []; context += "\n" + line; continue
            }
            let metadata = line.range(of: #"^(?:https?://|available until\b|due\b|closed\b|no submission|score:|assignment not|\d+ points|published\b|posted\b|date\s*:|(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)\w*\s+\d)"#, options: [.regularExpression, .caseInsensitive]) != nil
            if metadata { body.append(line) }
            else if line.count > 4 && line != "Assignment" && line != "Quiz" && !line.hasPrefix("----") {
                flush(); title = replace(#"^[#\s*\-]+"#, line); body = []
            }
        }
        flush(); return result
    }
    private static func dateValue(_ text: String, reference: Date) -> (String, Int?)? {
        let value = EventParser.parse("主题：Canvas\n日期：" + text, reference: reference)
        guard value.foundDate else { return nil }
        return (value.task.day, value.task.startMinute)
    }
    private static func notificationDate(_ block: Block, reference: Date) -> Date? {
        let body = clean(block.body)
        let cells = body.components(separatedBy: CharacterSet(charactersIn: "|\n")).map(clean)
        let datePattern = #"^(?:(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)\w*\s+\d{1,2}|20\d{2}[-/.年]\d{1,2})"#
        let labeled = cells.compactMap { cell -> String? in
            let stripped = replace(#"^(?:posted|published|sent|date|通知时间|发布时间)\s*[:：]\s*"#, cell)
            return stripped != cell ? stripped : nil
        }
        let dates = labeled + cells.filter { $0.range(of: datePattern, options: [.regularExpression, .caseInsensitive]) != nil }
        guard let value = dates.last.flatMap({ dateValue($0, reference: reference) }), let day = Day.date(value.0) else { return nil }
        return Day.calendar.date(byAdding: .minute, value: value.1 ?? 720, to: Day.calendar.startOfDay(for: day))
    }
    private static func deadline(_ text: String, reference: Date) -> (String, Int?)? {
        let pattern = #"(?:\bnew\s+due\s+date\b|\bdue\b(?!\s+date\s+changed)|\bdeadline\b|截止(?:时间|日期)?|延期(?:到|至)|延后(?:到|至))\s*[:：]?\s*([^|\n]*)"#
        for m in matches(pattern, text) {
            let clause = replace(#"^(?:now\s+)?(?:on|at|to|is|date)\s*[:：]?\s*"#, clean(m[1]))
            if let date = dateValue(clause, reference: reference) { return date }
        }
        return nil
    }
    static func parse(_ raw: String, reference: Date = Date()) -> [CanvasCandidate] {
        let limited = String(raw.prefix(100_000))
        let text = limited.contains("<a ") || limited.contains("<table") ? textFromHTML(limited) : clean(limited)
        let sections = blocks(text)
        let courseIDs = Set(matches(#"/courses/(\d+)/"#, text).map { $0[1] })
        let codes = Set(matches(#"\b([A-Z]{2,8}\s?\d{3,4})\b"#, text).map { $0[1].uppercased() })
        var results: [CanvasCandidate] = []
        for block in sections {
            let whole = block.title + "\n" + block.body
            let notification = block.url?.contains("/announcements/") == true || block.title.range(of: #"assignment (?:due date changed|created)"#, options: [.regularExpression, .caseInsensitive]) != nil
            let posted = notification ? notificationDate(block, reference: reference) : nil
            let anchor = posted ?? reference
            let due = deadline(whole, reference: anchor)
            let event = block.title.range(of: #"class starts|上课|开课"#, options: [.regularExpression, .caseInsensitive]) != nil
            let relative = whole.range(of: #"\btoday\b|\btomorrow\b|今天|明天"#, options: [.regularExpression, .caseInsensitive]) != nil
            let eventDate = event && (!relative || posted != nil) ? dateValue(block.title, reference: anchor) : nil
            let info = block.url?.contains("/announcements/") == true && due == nil && !event
            let closed = whole.range(of: #"\bclosed\b|\bscore\s*:|已关闭|已评分"#, options: [.regularExpression, .caseInsensitive]) != nil
            let assignment = block.url.flatMap(assignmentIdentity)
            let uri = block.url.flatMap(WebLink.safe)
            let courseID = uri.flatMap { matches(#"/courses/(\d+)/"#, $0.path).first?[1] }
            let code = matches(#"\b([A-Z]{2,8}\s?\d{3,4})\b"#, block.title).first?[1].uppercased()
                ?? (codes.count == 1 && courseIDs.count <= 1 ? codes.first : nil)
                ?? matches(#"\b([A-Z]{2,8}\s?\d{3,4})\b"#, block.context).last?[1].uppercased()
            let scope = uri.flatMap { u in courseID.map { (u.host?.lowercased() ?? "") + "/courses/" + $0 } }
                ?? code.map { "course-code/" + $0 } ?? "unscoped/" + UUID().uuidString
            let nums = matches(#"\bAssignment\s*#?\s*(\d+)(?:\s*(?:and|&|、|和)\s*(?:Assignment\s*)?#?\s*(\d+))?"#, block.title)
                .flatMap { [$0[1], $0[2]] }.filter { !$0.isEmpty }
            let numbers = Array(Set(nums)).sorted()
            let split = block.url?.contains("/announcements/") == true && due != nil && !numbers.isEmpty
            let items: [String?] = split ? numbers.map(Optional.some) : [nil]
            for number in items {
                let aliases = (number.map { [$0] } ?? (info ? [] : numbers)).map { scope + "/assignment-number/" + $0 }
                let identity = assignment ?? (aliases.first ?? block.url ?? UUID().uuidString)
                let source = CanvasReference(identities: Array(Set([identity] + aliases)).sorted(), assignmentIdentity: assignment,
                    notifiedAt: posted, noticeURL: notification ? block.url : nil, isDeadline: !event)
                let stripped = replace(#"^Assignment\s+(?:Due Date Changed|Created)\s*[:\-–]\s*"#, block.title)
                let displayTitle = number.map { "Assignment " + $0 } ?? stripped
                let title = code.map { displayTitle.localizedCaseInsensitiveContains($0) ? displayTitle : $0 + " · " + displayTitle } ?? displayTitle
                let value = due ?? eventDate
                var warnings: [String] = []
                if value == nil { warnings.append(info ? "信息通知，默认不加入待办。" : "未提供明确截止日期，请查看原文后填写。") }
                if due != nil && due?.1 == nil { warnings.append("原文只写了日期，未写具体时刻；可保留为当天待办。") }
                if notification && posted == nil { warnings.append("未找到通知发布时间，无法自动判断新旧。") }
                if event && relative && posted == nil { warnings.append("“今天”需要通知的发布日期才能确定。") }
                if closed { warnings.append("已关闭或已评分，默认不导入。") }
                let past = value.map { $0.0 < Day.key(reference) } ?? false
                if past && !closed { warnings.append("日期已过，默认不导入。") }
                if uri == nil { warnings.append("未保留 Canvas 链接；复制带链接的内容可更可靠地更新同一份作业。") }
                let needsReview = value == nil || (due != nil && due?.1 == nil)
                results.append(CanvasCandidate(title: title, day: value?.0, minute: value?.1, source: source,
                    link: block.url, original: String(whole.prefix(25_000)), warnings: warnings, informational: info,
                    closed: closed, past: past, selected: value != nil && !info && !closed && !needsReview && !past, requiresConfirmation: needsReview))
            }
        }
        return collapse(results)
    }
    static func collapse(_ items: [CanvasCandidate]) -> [CanvasCandidate] {
        var groups: [[CanvasCandidate]] = []
        for item in items {
            let keys = Set(item.source.identities)
            let matching = groups.indices.filter { i in groups[i].contains { !keys.isDisjoint(with: $0.source.identities) } }
            if matching.isEmpty { groups.append([item]); continue }
            let combined = matching.flatMap { groups[$0] } + [item]
            for i in matching.reversed() { groups.remove(at: i) }
            groups.append(combined)
        }
        return groups.map { group in
            let sorted = group.sorted {
                if $0.source.notifiedAt != $1.source.notifiedAt { return ($0.source.notifiedAt ?? .distantPast) > ($1.source.notifiedAt ?? .distantPast) }
                if ($0.day != nil) != ($1.day != nil) { return $0.day != nil }
                return $0.original < $1.original
            }
            var result = sorted[0]
            result.source.identities = Array(Set(group.flatMap { $0.source.identities })).sorted()
            result.mergedCount = group.reduce(0) { $0 + $1.mergedCount }
            if let detail = group.filter({ $0.source.assignmentIdentity != nil }).max(by: { $0.title.count < $1.title.count }) {
                result.title = detail.title; result.link = detail.link; result.source.assignmentIdentity = detail.source.assignmentIdentity
            }
            let tied = group.filter { $0.source.notifiedAt == result.source.notifiedAt && $0.day != nil }
            if Set(tied.map { ($0.day ?? "") + ":" + String($0.minute ?? -1) }).count > 1 {
                result.warnings.append("相同发布时间的截止信息有冲突，请查看原文确认。")
                result.requiresConfirmation = true; result.selected = false
            }
            if result.mergedCount > 1 { result.warnings.append("已合并 \(result.mergedCount) 条记录，以最新通知为准。") }
            return result
        }.sorted {
            func rank(_ item: CanvasCandidate) -> Int {
                if item.informational || item.closed || item.past { return 2 }
                return item.day == nil ? 1 : 0
            }
            return (rank($0), $0.day ?? "9999", $0.title) < (rank($1), $1.day ?? "9999", $1.title)
        }
    }
}
