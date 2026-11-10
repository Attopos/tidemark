import SwiftUI
import SwiftData
import UniformTypeIdentifiers

// MARK: - Root window: the portfolio, full stop

struct RootView: View {
    @Environment(AppState.self) private var app
    @Environment(\.modelContext) private var context
    var storageError: String?

    @State private var dropTargeted = false

    var body: some View {
        @Bindable var app = app
        ZStack(alignment: .top) {
            DS.bgPrimary.ignoresSafeArea()
            PortfolioView()
            if let storageError {
                IssueBanner(issue: DataQualityIssue(severity: .warning,
                                                    icon: "externaldrive.badge.exclamationmark",
                                                    message: storageError))
                    .padding(.horizontal, DS.pagePadding)
                    .padding(.top, 8)
            }
        }
        .preferredColorScheme(.dark)
        .overlay {
            if dropTargeted { DropHint() }
        }
        .sheet(isPresented: $app.ocrImportPresented) {
            AlipayImportFlow()
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            handleDrop(providers)
        }
        .id(app.language)
        .environment(\.locale, app.language.locale)
        .onAppear {
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }
        .task {
            CurrencyService.ensureSeeds(in: context)
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
                        app.routeImport(url: url)
                    }
                }
            }
        }
        return handled
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
                Text(tr("Drop screenshots to import"))
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
