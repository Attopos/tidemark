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
                    case .portfolio: PortfolioView()
                    case .ledger: LedgerView()
                    case .accounts: AccountsView()
                    case .analysis: AnalysisView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        .preferredColorScheme(.dark)
        .tint(DS.accent)
        .overlay {
            if dropTargeted { DropHint() }
        }
        .sheet(isPresented: $app.ocrImportPresented) {
            ScreenshotImportFlow()
                .tint(DS.accent)
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            handleDrop(providers)
        }
        .id(app.language)
        .environment(\.locale, app.language.locale)
        .onAppear {
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }
        // Every saved change refreshes today's backup (see BackupService).
        .onReceive(NotificationCenter.default.publisher(for: ModelContext.didSave)
            .debounce(for: .seconds(2), scheduler: RunLoop.main)) { _ in
            app.backUp(context)
        }
        .task {
            CurrencyService.ensureSeeds(in: context)
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

/// Narrow icon rail on the left edge: one button per page, settings at the bottom.
private struct SectionRail: View {
    @Binding var selection: AppSection

    var body: some View {
        VStack(spacing: 6) {
            ForEach(AppSection.allCases) { section in
                let selected = section == selection
                Button { selection = section } label: {
                    VStack(spacing: 4) {
                        Image(systemName: section.icon)
                            .font(.system(size: 15, weight: .semibold))
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
            Spacer()
            SettingsLink {
                Image(systemName: "gearshape")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(DS.textSecondary)
                    .frame(width: 60, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(tr("Settings"))
        }
        .padding(.top, 44)
        .padding(.bottom, 14)
        .frame(width: 76)
        .background(DS.panel)
    }
}

private struct ImportNotice: View {
    let message: String
    let failed: Bool
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: failed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(failed ? DS.warning : DS.accent)
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
    var body: some View {
        ZStack {
            Color.black.opacity(0.35)
            VStack(spacing: 10) {
                Image(systemName: "text.viewfinder")
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(DS.accent)
                Text(tr("Drop screenshots or a bookkeeping export to import"))
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
