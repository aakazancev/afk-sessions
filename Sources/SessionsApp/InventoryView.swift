import SwiftUI
import SessionsInventory

/// Вкладка «Инвентарь»: подсказки, глобальное, проекты.
struct InventoryView: View {
    @EnvironmentObject var inv: InventoryStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let e = inv.error {
                Text(e).font(Theme.uiSmall).foregroundStyle(Theme.red).padding(.bottom, 6)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !inv.suggestions.isEmpty { suggestions }
                    global
                    ForEach(inv.projects, id: \.self) { project($0) }
                    Text("Скиллы по отдельности — /skill-doctor в Claude Code.")
                        .font(Theme.uiSmall).foregroundStyle(Theme.textFaint)
                }
                .padding(.trailing, 8)
            }
        }
        .onAppear { inv.refresh() }
    }

    // MARK: - Части

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Инвентарь").font(.system(size: 13, weight: .semibold))
                Text("MCP и плагины: что подключено и что реально вызывалось за \(inv.days) дн. "
                     + "Выключение применится в новых сессиях.")
                    .font(Theme.uiSmall).foregroundStyle(Theme.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if inv.loading { ProgressView().controlSize(.small) }
            Button("Обновить") { inv.refresh() }.buttonStyle(.borderless)
        }
        .padding(.bottom, 10)
    }

    private var suggestions: some View {
        section("Подсказки") {
            ForEach(inv.suggestions) { s in
                HStack {
                    Text(s.text).font(Theme.ui)
                    Spacer()
                    Button("Выключить") { inv.setDisabled(s.item, true, s.target) }
                        .buttonStyle(.borderless).foregroundStyle(Theme.orange)
                        .disabled(inv.loading)
                }
            }
        }
    }

    private var global: some View {
        section("Глобально") {
            ForEach(inv.globalTop) { item in
                if item.kind == .plugin {
                    DisclosureGroup {
                        ForEach(inv.children(of: item)) { row($0, indent: true) }
                    } label: { row(item) }
                } else {
                    row(item)
                }
            }
        }
    }

    private func project(_ p: String) -> some View {
        let own = inv.projectItems(p), off = inv.disabledHere(p)
        return section((p as NSString).abbreviatingWithTildeInPath) {
            ForEach(own) { row($0) }
            ForEach(off) { row($0, restoreIn: p) }
            if own.isEmpty && off.isEmpty {
                Text("Своих MCP нет").font(Theme.uiSmall).foregroundStyle(Theme.textFaint)
            }
        }
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(Theme.monoSmall).foregroundStyle(Theme.textDim)
            content()
        }
    }

    /// Выключен ли элемент там, где он показан.
    private func isOff(_ item: InventoryItem, restoreIn project: String?) -> Bool {
        if item.disabledGlobally || project != nil { return true }
        if case .project(let p) = item.scope { return item.disabledIn.contains(p) }
        return false
    }

    private func row(_ item: InventoryItem, indent: Bool = false, restoreIn project: String? = nil) -> some View {
        // в секции проекта — вызовы именно в этом проекте
        var here = project
        if here == nil, case .project(let p) = item.scope { here = p }
        let count = here.map { inv.usage.inProject(item.usageRefs, $0).count }
            ?? inv.usage.total(item.usageRefs).count
        let off = isOff(item, restoreIn: project)
        return HStack(spacing: 8) {
            Text(kindLabel(item.kind)).font(Theme.monoSmall).foregroundStyle(Theme.textFaint)
                .frame(width: 44, alignment: .leading)
            Text(item.kind == .plugin ? String(item.name.split(separator: "@").first ?? "") : item.name)
                .font(Theme.ui)
                .foregroundStyle(off ? Theme.textFaint : Theme.text)
                .strikethrough(off)
                .lineLimit(1).truncationMode(.middle)
            if item.unreadable {
                Text("не прочитан").font(Theme.uiSmall).foregroundStyle(Theme.red)
            }
            Spacer()
            Text(count == 0 ? "—" : "\(count)×").font(Theme.monoSmall).foregroundStyle(Theme.textDim)
            Text(item.weightTokens.map { "~\($0)" } ?? "").font(Theme.monoSmall).foregroundStyle(Theme.textFaint)
                .frame(width: 52, alignment: .trailing)
            action(item, off: off, restoreIn: project).frame(width: 84, alignment: .trailing)
        }
        .padding(.leading, indent ? 16 : 0)
        .help(item.source)
    }

    private func action(_ item: InventoryItem, off: Bool, restoreIn project: String?) -> some View {
        actionControl(item, off: off, restoreIn: project).disabled(inv.loading)
    }

    @ViewBuilder
    private func actionControl(_ item: InventoryItem, off: Bool, restoreIn project: String?) -> some View {
        if !item.toggleable {
            EmptyView()
        } else if off {
            Button("Вернуть") { inv.setDisabled(item, false, restoreTarget(item, project)) }
                .buttonStyle(.borderless)
        } else if case .project(let p) = item.scope {
            Button("Выключить") { inv.setDisabled(item, true, .project(p)) }.buttonStyle(.borderless)
        } else {
            disableMenu(item)
        }
    }

    private func restoreTarget(_ item: InventoryItem, _ project: String?) -> ToggleTarget {
        if let project { return .project(project) }
        if case .project(let p) = item.scope { return .project(p) }
        return .everywhere
    }

    private func disableMenu(_ item: InventoryItem) -> some View {
        Menu("Выключить") {
            if item.kind == .plugin || item.mcpOrigin == .userConfig {
                Button("Везде") { inv.setDisabled(item, true, .everywhere) }
            }
            ForEach(inv.projects, id: \.self) { p in
                Button("Только в \((p as NSString).lastPathComponent)") {
                    inv.setDisabled(item, true, .project(p))
                }
            }
        }
        .menuStyle(.borderlessButton).fixedSize()
    }

    private func kindLabel(_ k: ItemKind) -> String {
        switch k {
        case .plugin: return "plugin"
        case .skill: return "skill"
        case .agent: return "agent"
        case .mcp: return "mcp"
        case .connector: return "claude"
        }
    }
}
