import SwiftUI
import SwiftData

// MARK: - Templates, recurring records and instalments
//
// One list of saved records in three groups. A template only fills the
// record editor; a recurring record adds itself on every due date; an
// instalment plan does the same a fixed number of times (a purchase split
// into monthly payments, or a loan), then stops.

enum PresetType: String, CaseIterable, Identifiable {
    case template, recurring, instalment
    var id: String { rawValue }

    var title: String {
        switch self {
        case .template: return tr("Template")
        case .recurring: return tr("Recurring")
        case .instalment: return tr("Instalments")
        }
    }

    init(_ preset: RecordPreset) {
        if preset.schedule == nil { self = .template }
        else if preset.occurrenceLimit != nil { self = .instalment }
        else { self = .recurring }
    }
}

struct PresetsView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \RecordPreset.createdAt) private var presets: [RecordPreset]
    @Query private var accounts: [Account]

    @State private var editing: RecordPreset?
    @State private var creating: PresetType?
    var showsDone = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(tr("Templates & recurring"))
                    .font(DS.title(20))
                    .foregroundStyle(DS.textPrimary)
                Spacer()
                Menu {
                    ForEach(PresetType.allCases) { type in
                        Button(type.title) { creating = type }
                    }
                } label: {
                    Label(tr("Add"), systemImage: "plus")
                        .font(.system(size: 14, weight: .semibold))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                if showsDone {
                    Button(tr("Done")) { dismiss() }
                        .buttonStyle(GhostButtonStyle())
                        .keyboardShortcut(.cancelAction)
                }
            }
            if presets.isEmpty {
                Text(tr("Nothing saved yet. Save a template from the record editor, or add a recurring record or an instalment plan here."))
                    .font(DS.body)
                    .foregroundStyle(DS.textSecondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach([PresetType.recurring, .instalment, .template]) { type in
                        let group = presets.filter { PresetType($0) == type }
                        if !group.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(type.title)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(DS.textSecondary)
                                ForEach(group) { row($0, type: type) }
                            }
                        }
                    }
                }
            }
        }
        .editorSheet(width: 560)
        .sheet(item: $editing) { PresetEditor(preset: $0, type: PresetType($0)) }
        .sheet(item: $creating) { PresetEditor(preset: nil, type: $0) }
    }

    private func subtitle(_ preset: RecordPreset, type: PresetType) -> String {
        var parts: [String] = []
        if let account = accounts.first(where: { $0.id == preset.accountID }) { parts.append(account.name) }
        if let frequency = preset.schedule {
            parts.append(frequency.displayName)
            if let limit = preset.occurrenceLimit {
                parts.append(trf("%d of %d done", max(0, preset.generatedThrough + 1), limit))
            }
            if preset.isActive, let next = PresetScheduler.occurrence(
                preset.generatedThrough + 1, start: preset.startDate, frequency: frequency,
                endDate: preset.endDate, limit: preset.occurrenceLimit) {
                parts.append("\(tr("Next")) \(Fmt.dateMedium.string(from: next))")
            } else if !preset.isActive {
                parts.append(type == .instalment && preset.generatedThrough + 1 >= (preset.occurrenceLimit ?? 0)
                             ? tr("Finished") : tr("Paused"))
            }
        }
        return parts.joined(separator: " · ")
    }

    private func row(_ preset: RecordPreset, type: PresetType) -> some View {
        HStack(spacing: 12) {
            CategoryIcon(name: preset.subcategory.isEmpty ? preset.category : preset.subcategory,
                         kind: preset.kind, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(preset.name)
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundStyle(DS.textPrimary)
                    .lineLimit(1)
                Text(subtitle(preset, type: type))
                    .font(.system(size: 12))
                    .foregroundStyle(DS.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(Fmt.money(preset.amount, preset.currencyCode))
                .font(DS.money(14, weight: .semibold))
                .foregroundStyle(FlowPalette.amountColor(preset.kind))
                .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(DS.tile)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { editing = preset }
        .contextMenu {
            Button(tr("Edit…")) { editing = preset }
            if type != .template {
                Button(preset.isActive ? tr("Pause") : tr("Resume")) {
                    preset.isActive.toggle()
                    preset.updatedAt = Date()
                    try? context.save()
                    PresetScheduler.run(in: context)
                }
            }
            Button(tr("Delete"), role: .destructive) {
                context.delete(preset)
                try? context.save()
            }
        }
    }
}

// MARK: - Preset editor

struct PresetEditor: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Account.createdAt) private var allAccounts: [Account]

    let preset: RecordPreset?
    @State private var type: PresetType
    @State private var name: String
    @State private var kind: TransactionKind
    @State private var amountText: String
    @State private var currency: String
    @State private var category: String
    @State private var subcategory: String
    @State private var accountID: UUID?
    @State private var transferAccountID: UUID?
    @State private var note: String
    @State private var frequency: Frequency
    @State private var start: Date
    @State private var hasEnd: Bool
    @State private var end: Date
    @State private var countText: String
    @State private var totalText = ""

    private static let kinds: [TransactionKind] = [.expense, .income, .transfer, .liabilityPayment]
    private static let frequencies: [Frequency] = [.weekly, .monthly, .quarterly, .yearly]

    init(preset: RecordPreset?, type: PresetType) {
        self.preset = preset
        let text: (Decimal) -> String = { $0 == 0 ? "" : NSDecimalNumber(decimal: $0).stringValue }
        _type = State(initialValue: type)
        _name = State(initialValue: preset?.name ?? "")
        _kind = State(initialValue: preset?.kind ?? (type == .instalment ? .liabilityPayment : .expense))
        _amountText = State(initialValue: preset.map { text($0.amount) } ?? "")
        _currency = State(initialValue: preset?.currencyCode ?? "CNY")
        _category = State(initialValue: preset?.category ?? "")
        _subcategory = State(initialValue: preset?.subcategory ?? "")
        _accountID = State(initialValue: preset?.accountID)
        _transferAccountID = State(initialValue: preset?.transferAccountID)
        _note = State(initialValue: preset?.note ?? "")
        _frequency = State(initialValue: preset?.schedule ?? .monthly)
        _start = State(initialValue: preset?.startDate ?? Date())
        _hasEnd = State(initialValue: preset?.endDate != nil)
        _end = State(initialValue: preset?.endDate ?? Calendar.current.date(byAdding: .year, value: 1, to: Date())!)
        _countText = State(initialValue: preset?.occurrenceLimit.map(String.init) ?? "12")
    }

    private var accounts: [Account] { allAccounts.filter { $0.isLedgerAccount && !$0.isArchived } }
    private var isFlow: Bool { kind == .expense || kind == .income }

    private static func decimal(_ text: String) -> Decimal? {
        let cleaned = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "")
        guard let value = Decimal(string: cleaned, locale: Locale(identifier: "en_US_POSIX")), value > 0 else { return nil }
        return value
    }

    private var count: Int? { Int(countText.trimmingCharacters(in: .whitespaces)).flatMap { $0 > 0 ? $0 : nil } }
    private var canSave: Bool {
        Self.decimal(amountText) != nil && (type != .instalment || count != nil)
            && (isFlow || accountID != nil || transferAccountID != nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(preset == nil ? tr("New") + " · " + type.title : type.title)
                .font(DS.title(20))
                .foregroundStyle(DS.textPrimary)
            CapsuleSwitch(options: PresetType.allCases, selection: $type) { $0.title }
            CapsuleSwitch(options: Self.kinds, selection: $kind) { $0.displayName }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                row(tr("Name")) { field($name, placeholder: tr("e.g. Rent")) }
                if type == .instalment {
                    row(tr("Total")) {
                        HStack(spacing: 8) {
                            field($totalText, placeholder: tr("0.00")).amountKeyboard()
                            Button(tr("Split")) {
                                if let total = Self.decimal(totalText), let count {
                                    amountText = NSDecimalNumber(decimal: (total / Decimal(count)).rounded(2)).stringValue
                                }
                            }
                            .buttonStyle(GhostButtonStyle())
                        }
                    }
                }
                row(type == .instalment ? tr("Each payment") : tr("Amount")) {
                    HStack(spacing: 8) {
                        field($amountText, placeholder: tr("0.00")).amountKeyboard()
                        field($currency, placeholder: "CNY").frame(width: 70)
                    }
                }
                if isFlow {
                    row(tr("Category")) {
                        HStack(spacing: 8) {
                            field($category, placeholder: tr("Category"))
                            field($subcategory, placeholder: tr("Subcategory"))
                        }
                    }
                }
                row(isFlow ? tr("Account") : tr("From")) { accountPicker($accountID) }
                if !isFlow { row(tr("To")) { accountPicker($transferAccountID) } }
                row(tr("Note")) { field($note, placeholder: "") }
                if type != .template {
                    row(tr("Repeats")) {
                        CapsuleSwitch(options: Self.frequencies, selection: $frequency) { $0.displayName }
                    }
                    row(tr("First on")) {
                        DatePicker("", selection: $start).labelsHidden().datePickerStyle(.compact)
                    }
                    if type == .instalment {
                        row(tr("Payments")) { field($countText, placeholder: "12").frame(width: 80) }
                    } else {
                        row(tr("Ends")) {
                            HStack {
                                Toggle(tr("On a date"), isOn: $hasEnd).toggleStyle(LimeCheckboxStyle())
                                    .foregroundStyle(DS.textSecondary)
                                if hasEnd {
                                    DatePicker("", selection: $end, displayedComponents: .date).labelsHidden()
                                }
                            }
                        }
                    }
                }
            }
            if type != .template {
                Text(tr("Records are added on each due date, including dates already past. Deleting one does not bring it back."))
                    .font(.system(size: 12))
                    .foregroundStyle(DS.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button(tr("Cancel")) { dismiss() }
                    .buttonStyle(GhostButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button(tr("Save")) { save() }
                    .buttonStyle(AccentButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
                    .opacity(canSave ? 1 : 0.45)
            }
        }
        .editorSheet(width: 520)
    }

    private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        GridRow {
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(DS.textSecondary)
                .frame(width: 92, alignment: .leading)
            content()
        }
    }

    private func field(_ text: Binding<String>, placeholder: String) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(.system(size: 14))
            .foregroundStyle(DS.textPrimary)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(DS.tile)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func accountPicker(_ selection: Binding<UUID?>) -> some View {
        Picker("", selection: selection) {
            Text("—").tag(UUID?.none)
            ForEach(accounts) { account in
                Text("\(account.name) · \(account.currencyCode)").tag(Optional(account.id))
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .tint(DS.textPrimary)
    }

    private func save() {
        guard let amount = Self.decimal(amountText) else { return }
        let target = preset ?? RecordPreset(name: "", kind: kind, amount: amount)
        let fallbackName = CategoryName.label(subcategory.isEmpty ? (category.isEmpty ? kind.displayName : category) : subcategory)
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        target.name = trimmed.isEmpty ? fallbackName : trimmed
        target.kind = kind
        target.amount = amount
        target.currencyCode = currency.trimmingCharacters(in: .whitespaces).uppercased().isEmpty
            ? "CNY" : currency.trimmingCharacters(in: .whitespaces).uppercased()
        target.category = isFlow ? category.trimmingCharacters(in: .whitespaces) : (kind == .liabilityPayment ? "Repayment" : "Transfer")
        target.subcategory = isFlow ? subcategory.trimmingCharacters(in: .whitespaces) : ""
        target.accountID = accountID
        target.transferAccountID = isFlow ? nil : transferAccountID
        target.note = note
        switch type {
        case .template:
            target.schedule = nil
            target.occurrenceLimit = nil
            target.endDate = nil
        case .recurring:
            target.schedule = frequency
            target.occurrenceLimit = nil
            target.endDate = hasEnd ? end : nil
        case .instalment:
            target.schedule = frequency
            target.occurrenceLimit = count
            target.endDate = nil
        }
        target.startDate = start
        if type != .template, preset == nil || !target.isActive && (target.occurrenceLimit ?? .max) > target.generatedThrough + 1 {
            target.isActive = true
        }
        target.updatedAt = Date()
        if preset == nil { context.insert(target) }
        try? context.save()
        PresetScheduler.run(in: context)
        dismiss()
    }
}
