import Foundation
import SessionsCore

/// Раз в сутки смотрит последний релиз на GitHub. Ошибки, 404 (релизов нет) — молча.
@MainActor
final class UpdateChecker: ObservableObject {

    struct Release: Equatable { let version: String; let url: URL }

    @Published private(set) var available: Release?

    private static let api = URL(string: "https://api.github.com/repos/aakazancev/afk-sessions/releases/latest")!
    private var timer: Timer?

    func start() {
        check()
        let t = Timer(timeInterval: 24 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.check() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func check() {
        let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        var req = URLRequest(url: Self.api)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 20
        Task { [weak self] in
            guard let (data, resp) = try? await URLSession.shared.data(for: req),
                  (resp as? HTTPURLResponse)?.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String,
                  let page = (json["html_url"] as? String).flatMap(URL.init(string:)),
                  json["draft"] as? Bool != true, json["prerelease"] as? Bool != true,
                  Version.isNewer(tag, than: current) else { return }
            let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            self?.available = Release(version: version, url: page)
        }
    }
}
