import SwiftUI
import SwiftData

struct RecordDetailView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Bindable var transaction: Transaction

    @State private var editing = false
    @State private var confirmingDelete = false

    private struct Row: Identifiable {
        let label: String
        let value: String
        var opensEditor = true
        var id: String { label }
    }

    private var none: String { tr("None") }

    private var typeText: String {
        let isFlow = transaction.kind == .expense || transaction.kind == .income
        let category = [transaction.category, transaction.subcategory].filter { !$0.isEmpty }.joined(separator: "-")
        let kindName = isFlow ? transaction.kind.displayName
                              : tr(LedgerExportType.canonical(transaction.category.isEmpty
                                                              ? transaction.kind.displayName : transaction.category))
        if isFlow { return category.isEmpty ? "(\(kindName))" : "(\(kindName)) \(category)" }
        return "(\(transaction.kind.displayName)) \(kindName)"
    }

    private var ledger: String? {
        guard let raw = transaction.rawPayload, let data = raw.data(using: .utf8),
              let fields = try? JSONDecoder().decode([String: String].self, from: data) else { return nil }
        let value = fields["Ledger"] ?? fields["账本"] ?? ""
        return value.isEmpty ? nil : value
    }

    private func accountText(_ account: Account?) -> String {
        guard let account else { return none }
        let type = account.typeLabel.isEmpty ? account.guessedTypeLabel : account.typeLabel
        return type.isEmpty ? account.name : "\(account.name) (\(type))"
    }

    private var currencyText: String {
        let code = transaction.currencyCode.uppercased()
        let name = L10n.current.locale.localizedString(forCurrencyCode: code) ?? code
        return name == code ? code : "\(name) (\(code))"
    }

    private func money(_ value: Decimal) -> String {
        value == 0 ? none : Fmt.money(value, transaction.currencyCode)
    }

    private var groups: [[Row]] {
        let isFlow = transaction.kind == .expense || transaction.kind == .income
        var first = [Row(label: tr("Type"), value: typeText)]
        if let ledger { first.append(Row(label: tr("Ledger"), value: ledger)) }

        var second = [
            Row(label: tr("Date"), value: Fmt.dateTime.string(from: transaction.date)),
            Row(label: tr("Amount"), value: Fmt.money(transaction.amount, transaction.currencyCode)),
            Row(label: tr("Currency"), value: currencyText),
        ]
        if isFlow {
            second.append(Row(label: tr("Account"), value: accountText(transaction.account)))
        } else {
            second.append(Row(label: tr("From account"), value: accountText(transaction.account)))
            second.append(Row(label: tr("To account"), value: accountText(transaction.transferAccount)))
            if let arrival = transaction.transferAmount, let target = transaction.transferAccount {
                second.append(Row(label: tr("Arrived"), value: Fmt.money(arrival, target.currencyCode)))
            }
        }

        let remark = transaction.note.trimmingCharacters(in: .whitespacesAndNewlines)
        let third = [
            Row(label: tr("Remark"), value: remark.isEmpty ? none : remark),
            Row(label: tr("Image"), value: none, opensEditor: false),
            Row(label: tr("Address"), value: transaction.address.isEmpty ? none : transaction.address),
        ]

        var fourth: [Row] = []
        if transaction.kind == .expense {
            fourth.append(Row(label: tr("Discount"), value: money(transaction.discountAmount)))
            if transaction.refundAmount > 0 { fourth.append(Row(label: tr("Refund"), value: money(transaction.refundAmount))) }
            if transaction.claimStatus != .none {
                var value = transaction.claimStatus.displayName
                if transaction.claimStatus == .claimed { value += " · \(money(transaction.claimAmount))" }
                fourth.append(Row(label: tr("Reimbursement"), value: value))
            }
        }
        if transaction.feeAmount > 0 { fourth.append(Row(label: tr("Fee"), value: money(transaction.feeAmount))) }
        return [first, second, third, fourth].filter { !$0.isEmpty }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    actions
                    ForEach(Array(groups.enumerated()), id: \.offset) { _, rows in card(rows) }
                    if transaction.canBeExcluded { excludeCard }
                }
                .padding(.horizontal, margin)
                .padding(.top, 6)
                .padding(.bottom, 40)
            }
            .scrollIndicators(.hidden)
        }
        .background(DS.page)
        #if os(macOS)
        .frame(width: 480, height: 680)
        #endif
        .sheet(isPresented: $editing) { TransactionEditor(transaction: transaction) }
        .confirmationDialog(tr("Delete this record?"), isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button(tr("Delete"), role: .destructive) {
                context.delete(transaction)
                try? context.save()
                dismiss()
            }
            Button(tr("Cancel"), role: .cancel) {}
        }
    }

    private var margin: CGFloat {
        #if os(iOS)
        DS.phoneMargin
        #else
        22
        #endif
    }

    private var header: some View {
        ZStack {
            Text(tr("Record Details"))
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(DS.textPrimary)
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(DS.textPrimary)
                        .frame(width: 40, height: 40)
                        .background(DS.tile)
                        .clipShape(Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tr("Back"))
                Spacer()
            }
        }
        .padding(.horizontal, margin)
        .padding(.top, 18)
        .padding(.bottom, 12)
    }

    private var actions: some View {
        HStack(spacing: 12) {
            actionTile(tr("Edit"), symbol: "pencil", tint: DS.accentText) { editing = true }
            actionTile(tr("Delete"), symbol: "trash", tint: FlowPalette.expense) { confirmingDelete = true }
            Spacer(minLength: 0)
        }
    }

    private func actionTile(_ title: String, symbol: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 21, weight: .regular))
                Text(title)
                    .font(.system(size: 15, weight: .regular))
            }
            .foregroundStyle(tint)
            .frame(width: 92, height: 82)
            .background(DS.panel)
            .clipShape(RoundedRectangle(cornerRadius: DS.tileRadius, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func card(_ rows: [Row]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                Button { if row.opensEditor { editing = true } } label: { rowView(row) }
                    .buttonStyle(.plain)
                if index < rows.count - 1 {
                    Divider().overlay(DS.border.opacity(0.5)).padding(.leading, 18)
                }
            }
        }
        .background(DS.panel)
        .clipShape(RoundedRectangle(cornerRadius: DS.panelRadius, style: .continuous))
    }

    private func rowView(_ row: Row) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Text(row.label)
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(DS.textPrimary)
                .fixedSize()
            Spacer(minLength: 12)
            Text(row.value)
                .font(.system(size: 15, weight: .regular).monospacedDigit())
                .foregroundStyle(DS.textSecondary)
                .multilineTextAlignment(.trailing)
                .lineLimit(3)
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(DS.textTertiary)
                .opacity(row.opensEditor ? 1 : 0)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(minHeight: 54)
        .contentShape(Rectangle())
    }

    private var excludeCard: some View {
        Toggle(isOn: Binding(get: { transaction.excludeFromStats },
                             set: { _ in transaction.toggleExcluded(in: context) })) {
            Text(transaction.kind == .income ? tr("Exclude from income") : tr("Exclude from expense"))
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(DS.textPrimary)
        }
        .toggleStyle(.switch)
        .tint(DS.accent)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .frame(minHeight: 54)
        .background(DS.panel)
        .clipShape(RoundedRectangle(cornerRadius: DS.panelRadius, style: .continuous))
    }
}
