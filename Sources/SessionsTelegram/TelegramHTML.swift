import Foundation

/// Markdown финальных ответов Claude → HTML для parse_mode "HTML" Bot API.
/// Только теги, которые понимает Telegram: b, i, code, pre, a. Тег выводится,
/// лишь когда найдена закрывающая пара, — незакрытая разметка остаётся текстом,
/// поэтому теги всегда сбалансированы.
public enum TelegramHTML {

    /// Telegram требует экранировать только & < > (вне тегов).
    public static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    public static func fromMarkdown(_ md: String) -> String {
        let lines = md.components(separatedBy: "\n")
        var out: [String] = []
        var i = 0
        while i < lines.count {
            // Блок ```lang … ```: внутри разметку не трогаем. Без закрытия — обычные строки.
            if isFence(lines[i]), let end = lines[(i + 1)...].firstIndex(where: isFence) {
                out.append("<pre>" + escape(lines[(i + 1)..<end].joined(separator: "\n")) + "</pre>")
                i = end + 1
                continue
            }
            out.append(line(Array(lines[i])))
            i += 1
        }
        return out.joined(separator: "\n")
    }

    // MARK: - Строка

    private static func isFence(_ s: String) -> Bool {
        s.trimmingCharacters(in: .whitespaces).hasPrefix("```")
    }

    private static func line(_ c: [Character]) -> String {
        // Заголовок «# …» — жирным.
        let hashes = c.prefix { $0 == "#" }.count
        if (1...6).contains(hashes), hashes < c.count, c[hashes] == " " {
            var rest = String(c[(hashes + 1)...]).trimmingCharacters(in: .whitespaces)
            // «# **Итог**» — уже жирный: без <b><b>.
            for m in ["**", "__"] where rest.count > 4 && rest.hasPrefix(m) && rest.hasSuffix(m) {
                rest = String(rest.dropFirst(2).dropLast(2))
            }
            if !rest.isEmpty { return "<b>" + inline(Array(rest)) + "</b>" }
        }
        // Маркер списка «- » / «* » (с отступом) — точка.
        let indent = c.prefix { $0 == " " || $0 == "\t" }.count
        if indent + 1 < c.count, c[indent] == "-" || c[indent] == "*", c[indent + 1] == " " {
            return String(c[..<indent]) + "• " + inline(Array(c[(indent + 2)...]))
        }
        return inline(c)
    }

    private static func inline(_ c: [Character]) -> String {
        var out = ""
        var i = 0
        while i < c.count {
            let ch = c[i]
            if ch == "`", let end = c[(i + 1)...].firstIndex(of: "`"), end > i + 1 {
                out += "<code>" + escape(String(c[(i + 1)..<end])) + "</code>"
                i = end + 1
                continue
            }
            if ch == "[", let (html, next) = link(c, at: i) {
                out += html
                i = next
                continue
            }
            if ch == "*" || ch == "_" {
                if i + 1 < c.count, c[i + 1] == ch {
                    if let end = closeDouble(c, at: i) {
                        out += "<b>" + inline(Array(c[(i + 2)..<end])) + "</b>"
                        i = end + 2
                    } else {
                        out += String([ch, ch])
                        i += 2
                    }
                    continue
                }
                if let end = closeSingle(c, at: i) {
                    out += "<i>" + inline(Array(c[(i + 1)..<end])) + "</i>"
                    i = end + 1
                    continue
                }
            }
            out += escape(String(ch))
            i += 1
        }
        return out
    }

    private static func isWord(_ ch: Character) -> Bool { ch.isLetter || ch.isNumber }

    /// Открывающий маркер не внутри слова и не перед пробелом.
    private static func canOpen(_ c: [Character], _ i: Int, width: Int) -> Bool {
        (i == 0 || !isWord(c[i - 1])) && i + width < c.count && !c[i + width].isWhitespace
    }

    /// Закрывающая пара для «**»/«__» в позиции i.
    private static func closeDouble(_ c: [Character], at i: Int) -> Int? {
        let ch = c[i]
        guard canOpen(c, i, width: 2) else { return nil }
        var j = i + 3
        while j + 1 < c.count {
            if c[j] == ch, c[j + 1] == ch, !c[j - 1].isWhitespace,
               j + 2 == c.count || !isWord(c[j + 2]) { return j }
            j += 1
        }
        return nil
    }

    /// Закрывающий одиночный «*»/«_» в позиции i (не часть «**»).
    private static func closeSingle(_ c: [Character], at i: Int) -> Int? {
        let ch = c[i]
        guard canOpen(c, i, width: 1) else { return nil }
        var j = i + 2
        while j < c.count {
            if c[j] == ch, c[j - 1] != ch, !c[j - 1].isWhitespace,
               j + 1 == c.count || (c[j + 1] != ch && !isWord(c[j + 1])) { return j }
            j += 1
        }
        return nil
    }

    /// [текст](http…) → <a>. Ссылки без схемы (пути к файлам) Telegram не примет — не трогаем.
    private static func link(_ c: [Character], at i: Int) -> (String, Int)? {
        guard let close = c[(i + 1)...].firstIndex(of: "]"), close > i + 1,
              close + 1 < c.count, c[close + 1] == "(",
              let paren = c[(close + 2)...].firstIndex(of: ")") else { return nil }
        let url = String(c[(close + 2)..<paren])
        guard url.hasPrefix("http://") || url.hasPrefix("https://"),
              !url.contains(where: \.isWhitespace) else { return nil }
        let href = escape(url).replacingOccurrences(of: "\"", with: "&quot;")
        // Внутри ссылки Telegram не допускает code — только экранированный текст без обратных кавычек.
        let text = escape(String(c[(i + 1)..<close]).replacingOccurrences(of: "`", with: ""))
        return ("<a href=\"\(href)\">" + text + "</a>", paren + 1)
    }
}
