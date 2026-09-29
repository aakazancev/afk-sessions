import Foundation

/// Все пути к конфигам Claude Code. home подменяется в тестах.
public struct ClaudePaths: Sendable {
    public var home: URL
    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) { self.home = home }

    public var claudeDir: URL        { home.appendingPathComponent(".claude") }
    public var claudeJSON: URL       { home.appendingPathComponent(".claude.json") }
    public var userSettings: URL     { claudeDir.appendingPathComponent("settings.json") }
    public var installedPlugins: URL { claudeDir.appendingPathComponent("plugins/installed_plugins.json") }
    public var transcripts: URL      { claudeDir.appendingPathComponent("projects") }

    public func projectDir(_ p: String) -> URL { URL(fileURLWithPath: p).appendingPathComponent(".claude") }
    public func projectSettings(_ p: String) -> URL { projectDir(p).appendingPathComponent("settings.json") }
    public func projectSettingsLocal(_ p: String) -> URL { projectDir(p).appendingPathComponent("settings.local.json") }
    public func projectMcpJSON(_ p: String) -> URL { URL(fileURLWithPath: p).appendingPathComponent(".mcp.json") }
}
