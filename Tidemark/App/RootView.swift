import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import Combine

// MARK: - Root window: a page rail and the selected page

struct RootView: View {
    @Environment(AppState.self) private var app
    @Environment(\.modelContext) private var context
    var storageError: String?

    @State private var dropTargeted = false

    var body: some View {
        @Bindable var app = app
        ZStack(alignment: .top) {
            DS.page.ignoresSafeArea()
            HStack(spacing: 0) {
                SectionRail(selection: $app.section)
                Group {
                    switch app.section {
                    case .portfolio:
                        if app.portfolioUnlocked { PortfolioView() } else { PortfolioLock() }
                    case .ledger: LedgerView()
                    case .accounts: AccountsView()
                    case .analysis: AnalysisView()
                    case .settings: SettingsView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if [.ledger, .accounts, .analysis].contains(app.section) {
                FloatingAddButton { app.addingRecord = true }
                    .keyboardShortcut("n", modifiers: .command)
                    .padding(28)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
            if let message = app.ledgerImportMessage {
                ImportNotice(message: message, failed: app.ledgerImportFailed) { app.ledgerImportMessage = nil }
                    .padding(.top, 10)
            }
            if let storageError {
                IssueBanner(issue: DataQualityIssue(severity: .warning,
                                                    icon: "externaldrive.badge.exclamationmark",
                                                    message: storageError))
                    .padding(.horizontal, DS.pagePadding)
                    .padding(.top, 8)
            }
        }
        .preferredColorScheme(app.appearance.colorScheme)
        .tint(DS.accentText)
        .overlay {
            if dropTargeted { DropHint() }
        }
        .sheet(isPresented: $app.addingRecord) { TransactionEditor(transaction: nil) }
        .sheet(item: $app.pendingReceipt) { TransactionEditor(transaction: nil, draft: $0.draft) }
        .sheet(isPresented: $app.ocrImportPresented) {
            ScreenshotImportFlow()
                .tint(DS.accentText)
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            handleDrop(providers)
        }
        .id("\(app.language.rawValue)-\(app.amountsHidden)")
        .environment(\.locale, app.language.locale)
        .onAppear { app.applyAppearance() }
        // Switching to another app locks the portfolio again.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            app.lockPortfolio()
        }
        // Recurring records and instalments due since last time.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            PresetScheduler.run(in: context)
        }
        // Every saved change refreshes today's backup (see BackupService).
        .onReceive(NotificationCenter.default.publisher(for: ModelContext.didSave)
            .debounce(for: .seconds(2), scheduler: RunLoop.main)) { _ in
            app.backUp(context)
        }
        .task {
            CurrencyService.ensureSeeds(in: context)
            PresetScheduler.run(in: context)
            app.backUp(context)
            // Daily rate: check hourly while the app is open; only fetches
            // when today's rate is missing, so it's one request per day.
            while !Task.isCancelled {
                await CurrencyService.refreshUSDIfStale(in: context)
                try? await Task.sleep(for: .seconds(3600))
            }
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            handled = true
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                var url: URL?
                if let direct = item as? URL {
                    url = direct
                } else if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                }
                if let url {
                    Task { @MainActor in
                        if url.pathExtension.lowercased() == "xlsx" {
                            app.importLedgerExport(url: url, into: context)
                        } else if app.section != .portfolio {
                            // On the cash pages a screenshot is a receipt.
                            app.importReceipt(url: url, context: context)
                        } else {
                            app.routeImport(url: url)
                        }
                    }
                }
            }
        }
        return handled
    }
}

// MARK: - Section rail

/// Narrow icon rail on the left edge: one button per page, settings included.
private struct SectionRail: View {
    @Binding var selection: AppSection
    @Environment(AppState.self) private var app

    var body: some View {
        VStack(spacing: 6) {
            ForEach([AppSection.ledger, .accounts, .analysis]) { button($0) }
            Spacer()
            // The portfolio is its own, locked block, apart from day-to-day cash.
            Divider().frame(width: 44).padding(.vertical, 6)
            button(.portfolio, badge: app.portfolioUnlocked ? "lock.open.fill" : "lock.fill")
            button(.settings)
        }
        .padding(.top, 44)
        .padding(.bottom, 14)
        .frame(width: 76)
        .background(DS.panel)
    }

    private func button(_ section: AppSection, badge: String? = nil) -> some View {
        let selected = section == selection
        return Button { selection = section } label: {
            VStack(spacing: 4) {
                Image(systemName: section.icon)
                    .font(.system(size: 15, weight: .semibold))
                    .overlay(alignment: .topTrailing) {
                        if let badge {
                            Image(systemName: badge)
                                .font(.system(size: 8, weight: .bold))
                                .offset(x: 9, y: -5)
                        }
                    }
                Text(section.title)
                    .font(.system(size: 10.5, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .foregroundStyle(selected ? DS.ink : DS.textSecondary)
            .frame(width: 60, height: 52)
            .background(selected ? DS.accent : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(section.title)
    }
}

/// Shown in place of the portfolio until the system password check passes.
private struct PortfolioLock: View {
    @Environment(AppState.self) private var app

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.fill")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(DS.textTertiary)
            Text(tr("Portfolio is locked"))
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(DS.textPrimary)
            Text(tr("Use your Mac password or Touch ID to open it. It locks again when you leave the page or the app."))
                .font(DS.body)
                .foregroundStyle(DS.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Button(tr("Unlock")) { Task { await app.unlockPortfolio() } }
                .buttonStyle(AccentButtonStyle())
                .keyboardShortcut(.defaultAction)
            if let message = app.unlockMessage {
                Text(message)
                    .font(DS.caption)
                    .foregroundStyle(DS.warning)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DS.page)
        // Ask straight away; the button is there after a cancel.
        .task { await app.unlockPortfolio() }
    }
}

private struct ImportNotice: View {
    let message: String
    let failed: Bool
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: failed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(failed ? DS.warning : DS.accentText)
            Text(message)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(DS.textPrimary)
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(DS.textSecondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(DS.bgElevated)
        .clipShape(Capsule())
        .overlay(Capsule().strokeBorder(DS.border, lineWidth: 1))
    }
}

private struct DropHint: View {
    @Environment(AppState.self) private var app

    var body: some View {
        ZStack {
            Color.black.opacity(0.35)
            VStack(spacing: 10) {
                Image(systemName: "text.viewfinder")
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(DS.accentText)
                Text(app.section == .portfolio ? tr("Drop holdings screenshots to import")
                     : tr("Drop a receipt screenshot or a bookkeeping export"))
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(DS.textPrimary)
            }
            .padding(28)
            .background(DS.bgElevated)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(DS.accent, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            )
        }
        .allowsHitTesting(false)
    }
}
