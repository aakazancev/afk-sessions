import Foundation

/// Отзывы и ошибки — Issues публичного репозитория.
enum Feedback {
    static let urlString = "https://github.com/aakazancev/afk-sessions/issues/new"
    static var url: URL? { urlString.isEmpty ? nil : URL(string: urlString) }
}
