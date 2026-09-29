import Foundation

/// Минимальный разбор YAML-frontmatter: плоские `key: value` и блочные
/// скаляры `key: >-` / `key: |` (строки с отступом склеиваются пробелом).
public enum Frontmatter {

    public static func parse(_ text: String) -> [String: String] {
        let lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return [:] }
        var out: [String: String] = [:]
        var blockKey: String?
        var block: [String] = []

        func flush() {
            if let k = blockKey { out[k] = block.joined(separator: " ") }
            blockKey = nil; block = []
        }

        for line in lines.dropFirst() {
            if line.trimmingCharacters(in: .whitespaces) == "---" { break }
            if blockKey != nil, line.hasPrefix(" ") || line.hasPrefix("\t") {
                block.append(line.trimmingCharacters(in: .whitespaces)); continue
            }
            flush()
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if [">", ">-", "|", "|-"].contains(value) { blockKey = key; continue }
            if value.count >= 2, value.first == "\"" || value.first == "'", value.last == value.first {
                value = String(value.dropFirst().dropLast())
            }
            out[key] = value
        }
        flush()
        return out
    }

    /// Грубая оценка: ~4 символа на токен.
    public static func tokens(name: String, description: String) -> Int {
        max(1, (name.count + description.count + 3) / 4)
    }
}
