import Foundation

/// Сравнение версий вида 0.7 / v0.7.1 (теги GitHub Releases).
public enum Version {
    /// true, если tag строго новее current. Нечисловые части — false (не предлагать обновление).
    public static func isNewer(_ tag: String, than current: String) -> Bool {
        guard let a = parts(tag), let b = parts(current) else { return false }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    static func parts(_ s: String) -> [Int]? {
        let t = s.hasPrefix("v") ? String(s.dropFirst()) : s
        let p = t.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !p.isEmpty, !p.contains(where: { $0 == nil }) else { return nil }
        return p.compactMap { $0 }
    }
}
