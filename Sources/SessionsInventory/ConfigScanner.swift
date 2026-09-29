import Foundation

/// Конфиги Claude Code → элементы инвентаря. Ничего не запускает.
public struct ConfigScanner {
    let paths: ClaudePaths
    /// Куда Toggler уносит глобальные MCP при «выключить везде»; nil — не читать.
    let stash: URL?
    private let fm = FileManager.default

    public init(paths: ClaudePaths, stash: URL? = nil) { self.paths = paths; self.stash = stash }

    public func scan(projects: [String]) -> [InventoryItem] {
        var items: [InventoryItem] = []

        // settings.json пользователя
        var settings: [String: Any] = [:]
        do { settings = try JSONFile.read(paths.userSettings) } catch {
            var bad = InventoryItem(kind: .plugin, name: "settings.json", scope: .global,
                                    source: paths.userSettings.path)
            bad.unreadable = true; bad.marker = true
            items.append(bad)
        }

        // Плагины
        let installed = ((try? JSONFile.read(paths.installedPlugins))?["plugins"] as? [String: Any]) ?? [:]
        for (key, value) in flags(settings).sorted(by: { $0.key < $1.key }) {
            let owner = String(key.split(separator: "@").first ?? Substring(key))
            let entry = (installed[key] as? [[String: Any]])?.first { $0["scope"] as? String == "user" }
            let installPath = entry?["installPath"] as? String

            var plugin = InventoryItem(kind: .plugin, name: key, scope: .global,
                                       source: paths.installedPlugins.path)
            plugin.disabledGlobally = (value == false)
            guard let installPath, fm.fileExists(atPath: installPath) else {
                plugin.unreadable = true
                items.append(plugin)
                continue
            }
            let root = URL(fileURLWithPath: installPath)
            var children = skills(in: root.appendingPathComponent("skills"), owner: owner, scope: .global)
            children += agents(in: root.appendingPathComponent("agents"), owner: owner, scope: .global)
            let mcpFile = root.appendingPathComponent(".mcp.json")
            for server in pluginServers(in: (try? JSONFile.read(mcpFile)) ?? [:]) {
                var m = InventoryItem(kind: .mcp, name: server, owner: owner, scope: .global,
                                      source: mcpFile.path, mcpOrigin: .plugin)
                m.usageRefs = ["mcp:plugin_\(McpName.normalize(owner))_\(McpName.normalize(server))"]
                children.append(m)
            }
            for i in children.indices { children[i].pluginKey = key }
            plugin.usageRefs = children.flatMap(\.usageRefs)
            let weights = children.compactMap(\.weightTokens)
            plugin.weightTokens = weights.isEmpty ? nil : weights.reduce(0, +)
            items.append(plugin)
            items += children
        }

        // ~/.claude.json
        var claude: [String: Any] = [:]
        do { claude = try JSONFile.read(paths.claudeJSON) } catch {
            var bad = InventoryItem(kind: .mcp, name: "~/.claude.json", scope: .global,
                                    source: paths.claudeJSON.path)
            bad.unreadable = true; bad.marker = true
            items.append(bad)
        }
        for server in servers(in: claude) {
            var m = InventoryItem(kind: .mcp, name: server, scope: .global,
                                  source: paths.claudeJSON.path, mcpOrigin: .userConfig)
            m.usageRefs = ["mcp:\(McpName.normalize(server))"]
            items.append(m)
        }

        // Stash: глобальные MCP, выключенные везде. Если имя снова есть в ~/.claude.json — пропуск.
        if let stash {
            do {
                let active = Set(servers(in: claude))
                for server in servers(in: try JSONFile.read(stash)) where !active.contains(server) {
                    var m = InventoryItem(kind: .mcp, name: server, scope: .global,
                                          source: stash.path, mcpOrigin: .userConfig)
                    m.disabledGlobally = true
                    m.usageRefs = ["mcp:\(McpName.normalize(server))"]
                    items.append(m)
                }
            } catch {
                var bad = InventoryItem(kind: .mcp, name: stash.lastPathComponent, scope: .global,
                                        source: stash.path)
                bad.unreadable = true; bad.marker = true
                items.append(bad)
            }
        }

        // Проекты
        let projectsConf = claude["projects"] as? [String: Any] ?? [:]
        for p in projects where fm.fileExists(atPath: p) {
            let conf = projectsConf[p] as? [String: Any] ?? [:]
            for server in servers(in: conf) {
                var m = InventoryItem(kind: .mcp, name: server, scope: .project(p),
                                      source: paths.claudeJSON.path, mcpOrigin: .projectConfig)
                m.usageRefs = ["mcp:\(McpName.normalize(server))"]
                items.append(m)
            }
            let mcpJSON = paths.projectMcpJSON(p)
            for server in servers(in: (try? JSONFile.read(mcpJSON)) ?? [:]) {
                var m = InventoryItem(kind: .mcp, name: server, scope: .project(p),
                                      source: mcpJSON.path, mcpOrigin: .mcpJSON)
                m.usageRefs = ["mcp:\(McpName.normalize(server))"]
                items.append(m)
            }

            // Выключения в проекте
            let disabledMcp = Set(conf["disabledMcpServers"] as? [String] ?? [])
            // settings.json и settings.local.json: плагины — по ключам (local важнее),
            // выключенные серверы .mcp.json — объединение.
            let shared = (try? JSONFile.read(paths.projectSettings(p))) ?? [:]
            let local = (try? JSONFile.read(paths.projectSettingsLocal(p))) ?? [:]
            let plugins = flags(shared).merging(flags(local)) { $1 }
            let mcpjsonOff = Set(shared["disabledMcpjsonServers"] as? [String] ?? [])
                .union(local["disabledMcpjsonServers"] as? [String] ?? [])

            for i in items.indices {
                let it = items[i]
                switch it.kind {
                case .plugin where plugins[it.name] == false:
                    items[i].disabledIn.insert(p)
                case .mcp where it.mcpOrigin == .userConfig && disabledMcp.contains(it.name):
                    items[i].disabledIn.insert(p)
                case .mcp where it.scope == .project(p) && it.mcpOrigin == .projectConfig
                                && disabledMcp.contains(it.name):
                    items[i].disabledIn.insert(p)
                case .mcp where it.scope == .project(p) && it.mcpOrigin == .mcpJSON
                                && mcpjsonOff.contains(it.name):
                    items[i].disabledIn.insert(p)
                default: break
                }
            }
        }
        return items
    }

    // MARK: - Разбор каталогов

    /// enabledPlugins → только булевы значения; прочие записи пропускаются.
    private func flags(_ json: [String: Any]) -> [String: Bool] {
        (json["enabledPlugins"] as? [String: Any] ?? [:]).compactMapValues { $0 as? Bool }
    }

    private func servers(in json: [String: Any]) -> [String] {
        (json["mcpServers"] as? [String: Any] ?? [:]).keys.sorted()
    }

    /// .mcp.json плагина бывает и без обёртки mcpServers (playwright):
    /// тогда серверы — ключи верхнего уровня со словарём в значении.
    private func pluginServers(in json: [String: Any]) -> [String] {
        if json["mcpServers"] != nil { return servers(in: json) }
        return json.filter { $0.value is [String: Any] }.keys.sorted()
    }

    private func skills(in dir: URL, owner: String?, scope: Scope) -> [InventoryItem] {
        let subdirs = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return subdirs.sorted { $0.path < $1.path }.compactMap { sub in
            let file = sub.appendingPathComponent("SKILL.md")
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
            let fmt = Frontmatter.parse(text)
            let name = fmt["name"] ?? sub.lastPathComponent
            var item = InventoryItem(kind: .skill, name: name, owner: owner, scope: scope,
                                     source: file.path,
                                     weightTokens: Frontmatter.tokens(name: name, description: fmt["description"] ?? ""))
            item.usageRefs = owner.map { ["skill:\($0):\(name)", "skill:\(name)"] } ?? ["skill:\(name)"]
            return item
        }
    }

    private func agents(in dir: URL, owner: String?, scope: Scope) -> [InventoryItem] {
        let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "md" }.sorted { $0.path < $1.path }.compactMap { file in
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
            let fmt = Frontmatter.parse(text)
            let name = fmt["name"] ?? file.deletingPathExtension().lastPathComponent
            var item = InventoryItem(kind: .agent, name: name, owner: owner, scope: scope,
                                     source: file.path,
                                     weightTokens: Frontmatter.tokens(name: name, description: fmt["description"] ?? ""))
            item.usageRefs = owner.map { ["agent:\($0):\(name)", "agent:\(name)"] } ?? ["agent:\(name)"]
            return item
        }
    }
}
