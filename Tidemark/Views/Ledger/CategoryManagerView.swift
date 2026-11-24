import SwiftUI
import SwiftData

struct CategoryManagerView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    var showsDone = true

    @State private var kind: TransactionKind = .expense
    @State private var stats = EntryStats()
    @State private var editing: CategoryEditTarget?
    private let styles = CategoryStyles.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                if showsDone {
                    Text(tr("Categories"))
                        .font(DS.title(20))
                        .foregroundStyle(DS.textPrimary)
                }
                Spacer()
                Button {
                    editing = CategoryEditTarget(kind: kind, name: "", parent: "", isNew: true)
                } label: {
                    Label(tr("Add"), systemImage: "plus")
                        .font(.system(size: 14, weight: .regular).monospacedDigit())
                }
                .buttonStyle(.plain)
                .foregroundStyle(DS.accentText)
                if showsDone {
                    Button(tr("Done")) { dismiss() }
                        .buttonStyle(GhostButtonStyle())
                        .keyboardShortcut(.cancelAction)
                }
            }
            Picker("", selection: $kind) {
                Text(TransactionKind.expense.displayName).tag(TransactionKind.expense)
                Text(TransactionKind.income.displayName).tag(TransactionKind.income)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(names, id: \.self) { name in
                        row(name, parent: "")
                        ForEach(subs(name), id: \.self) { sub in
                            row(sub, parent: name)
                        }
                    }
                }
                .background(DS.panel)
                .clipShape(RoundedRectangle(cornerRadius: DS.cardRadius, style: .continuous))
            }
            .scrollIndicators(.hidden)
        }
        .padding(showsDone ? 20 : 0)
        .frame(minWidth: showsDone ? 460 : nil, minHeight: showsDone ? 560 : nil)
        .background(showsDone ? DS.page : Color.clear)
        .task { reload() }
        .onReceive(NotificationCenter.default.publisher(for: CategoryStyles.didChange)) { _ in reload() }
        .onReceive(NotificationCenter.default.publisher(for: CategoryStyles.didReceive)) { _ in reload() }
        .sheet(item: $editing) { target in
            CategoryEditor(target: target, parents: names)
        }
    }

    private var names: [String] { stats.categories[kind] ?? [] }
    private func subs(_ parent: String) -> [String] { stats.subcategories[kind]?[parent] ?? [] }

    private func reload() {
        stats = EntryStats.load(context)
    }

    private func row(_ name: String, parent: String) -> some View {
        let indent = !parent.isEmpty
        return Button {
            editing = CategoryEditTarget(kind: kind, name: name, parent: parent, isNew: false)
        } label: {
            HStack(spacing: 12) {
                CategoryIcon(name: name, kind: kind, size: indent ? 28 : 34)
                Text(CategoryName.label(name))
                    .font(.system(size: 15).monospacedDigit())
                    .foregroundStyle(DS.textPrimary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12))
                    .foregroundStyle(DS.textTertiary)
            }
            .padding(.leading, indent ? 46 : 16)
            .padding(.trailing, 16)
            .frame(height: indent ? 46 : 54)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct CategoryEditTarget: Identifiable {
    let kind: TransactionKind
    let name: String
    let parent: String
    let isNew: Bool

    var id: String { "\(kind.rawValue)|\(parent)|\(name)|\(isNew)" }
}

private struct CategoryEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @State private var failure: String?
    let target: CategoryEditTarget
    let parents: [String]

    @State private var name = ""
    @State private var parent = ""
    @State private var symbol: String?
    private let styles = CategoryStyles.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Button(tr("Cancel")) { dismiss() }
                    .buttonStyle(GhostButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Text(target.isNew ? tr("New category") : CategoryName.label(target.name))
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(DS.textPrimary)
                Spacer()
                Button(tr("Save")) { save() }
                    .buttonStyle(AccentButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty)
            }
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(DS.bgElevated)
                    if let symbol {
                        Image(systemName: symbol)
                            .font(.system(size: 22))
                            .foregroundStyle(DS.textPrimary)
                    } else {
                        Text(String(trimmed.prefix(1)).uppercased())
                            .font(.system(size: 22, weight: .medium))
                            .foregroundStyle(DS.textPrimary)
                    }
                }
                .frame(width: 52, height: 52)
                if target.isNew {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField(tr("Name"), text: $name)
                            .textFieldStyle(.plain)
                            .font(.system(size: 17))
                            .padding(.horizontal, 12)
                            .frame(height: 38)
                            .background(DS.bgElevated)
                            .clipShape(RoundedRectangle(cornerRadius: DS.smallRadius, style: .continuous))
                        Picker(tr("Under"), selection: $parent) {
                            Text(tr("Top level")).tag("")
                            ForEach(parents, id: \.self) { Text(CategoryName.label($0)).tag($0) }
                        }
                        .pickerStyle(.menu)
                    }
                } else {
                    TextField(tr("Name"), text: $name)
                        .textFieldStyle(.plain)
                        .font(.system(size: 17))
                        .padding(.horizontal, 12)
                        .frame(height: 38)
                        .background(DS.bgElevated)
                        .clipShape(RoundedRectangle(cornerRadius: DS.smallRadius, style: .continuous))
                    if styles.isCustom(kind: target.kind, name: target.name, parent: target.parent) {
                        Button(tr("Delete"), role: .destructive) {
                            styles.remove(CustomCategory(kind: target.kind.rawValue, name: target.name, parent: target.parent))
                            dismiss()
                        }
                        .buttonStyle(GhostButtonStyle())
                    }
                }
            }
            if let failure {
                Text(failure).font(DS.caption).foregroundStyle(DS.negative)
            }
            CategoryIconPicker(selection: $symbol)
        }
        .padding(18)
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 600)
        #endif
        .background(DS.page)
        .onAppear {
            name = target.isNew ? "" : CategoryName.label(target.name)
            parent = target.parent
            symbol = target.isNew ? nil
                : styles.symbol(kind: target.kind, name: target.name) ?? EntryGlyph.symbol(for: target.name)
                    ?? CategoryName.glyph(for: target.name)
        }
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func save() {
        if target.isNew {
            styles.add(name: trimmed, parent: parent, kind: target.kind, symbol: symbol)
        } else {
            styles.setSymbol(symbol, kind: target.kind, name: target.name)
            let renamed = CategoryRenamer.fullName(replacingLabelOf: target.name, with: trimmed)
            if renamed != target.name {
                do {
                    _ = try CategoryRenamer.rename(kind: target.kind, name: target.name, parent: target.parent,
                                                   to: renamed, in: context)
                } catch {
                    failure = error.localizedDescription
                    return
                }
            }
        }
        dismiss()
    }
}

struct CategoryIconPicker: View {
    @Binding var selection: String?
    @State private var group = CategoryIconLibrary.groups.first?.key ?? ""
    @State private var query = ""

    private let columns = [GridItem(.adaptive(minimum: 44, maximum: 56), spacing: 8)]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(DS.textTertiary)
                TextField(trf("Search %d icons", CategoryIconLibrary.count), text: $query)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(DS.textTertiary)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(DS.bgElevated)
            .clipShape(RoundedRectangle(cornerRadius: DS.smallRadius, style: .continuous))
            if query.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(CategoryIconLibrary.groups) { item in
                            Button { group = item.key } label: {
                                Label(tr(item.title), systemImage: item.icon)
                                    .font(.system(size: 13))
                                    .padding(.horizontal, 10)
                                    .frame(height: 30)
                                    .background(Capsule().fill(group == item.key ? DS.accentDark : DS.bgElevated))
                                    .foregroundStyle(group == item.key ? DS.accentText : DS.textPrimary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .frame(height: 32)
            }
            ScrollView {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(symbols, id: \.self) { name in
                        Button { selection = name } label: {
                            Image(systemName: name)
                                .font(.system(size: 19))
                                .frame(width: 44, height: 44)
                                .background(Circle().fill(selection == name ? DS.accent : DS.bgElevated))
                                .foregroundStyle(selection == name ? DS.ink : DS.textPrimary)
                        }
                        .buttonStyle(.plain)
                        .help(name)
                    }
                }
                .padding(.vertical, 4)
            }
            .scrollIndicators(.hidden)
        }
    }

    private var symbols: [String] {
        if !query.isEmpty { return CategoryIconLibrary.search(query) }
        return CategoryIconLibrary.groups.first { $0.key == group }?.symbols ?? []
    }
}
