import SwiftUI
import SwiftData
import UniformTypeIdentifiers

// MARK: - Holdings screenshot OCR flow (Alipay funds, Binance assets)
//
// Drop/pick/paste screenshots → Vision OCR → review every parsed field beside
// the original image (uncertain values flagged) → explicit confirm → dated
// valuation snapshots, matched against existing holdings without duplication.

struct ScreenshotImportFlow: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query private var allHoldings: [Holding]

    @State private var session: ScreenshotImportSession?
    @State private var showFilePicker = false
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(DS.textSecondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)

            Group {
                if let session {
                    switch session.phase {
                    case .recognizing:
                        ProgressView().controlSize(.small)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    case .review:
                        OCRReviewStage(session: session,
                                       onSave: { session.commit(into: context) },
                                       onCancel: { dismiss() })
                    case .saving:
                        VStack(spacing: 12) {
                            ProgressView().controlSize(.small)
                            Text(tr("Saving holdings…")).font(DS.body).foregroundStyle(DS.textSecondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    case .done:
                        VStack(spacing: 14) {
                            Spacer()
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 36))
                                .foregroundStyle(DS.accentText)
                            Text(tr("Saved to Portfolio"))
                                .font(.system(size: 18, weight: .bold))
                                .foregroundStyle(DS.textPrimary)
                            Text(session.savedSummary)
                                .font(DS.body)
                                .foregroundStyle(DS.textSecondary)
                            Button(tr("Done")) { dismiss() }
                                .buttonStyle(AccentButtonStyle())
                                .keyboardShortcut(.defaultAction)
                            Spacer()
                        }
                        .frame(maxWidth: .infinity)
                    case .failed(let message):
                        VStack(spacing: 12) {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.system(size: 28))
                                .foregroundStyle(DS.negative)
                            Text(message)
                                .font(DS.body)
                                .foregroundStyle(DS.textSecondary)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: 520)
                            HStack {
                                Button(tr("Try another image…")) { self.session = nil }
                                    .buttonStyle(GhostButtonStyle())
                                Button(tr("Close")) { dismiss() }
                                    .buttonStyle(AccentButtonStyle())
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else {
                    pickStage
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 1020, height: 700)
        .background(DS.bgPrimary)
        .fileImporter(isPresented: $showFilePicker,
                      allowedContentTypes: [.png, .jpeg, .tiff, .heic, .image],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                let images = urls.compactMap { url -> NSImage? in
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    return NSImage(contentsOf: url)
                }
                if !images.isEmpty { start(images) }
            }
        }
        .onDrop(of: [.fileURL, .image], isTargeted: $dropTargeted) { providers in
            handleDrop(providers)
        }
        .onPasteCommand(of: [.image, .png, .tiff, .fileURL]) { _ in
            pasteFromClipboard()
        }
        .onAppear {
            if !app.pendingOCRImages.isEmpty {
                let images = app.pendingOCRImages
                app.pendingOCRImages = []
                start(images)
            }
        }
    }

    private func start(_ images: [NSImage]) {
        let newSession = ScreenshotImportSession(images: images)
        session = newSession
        // Sold holdings too: a re-bought fund reopens its old entry.
        let holdings = allHoldings
        Task { await newSession.run(existingHoldings: holdings) }
    }

    private func pasteFromClipboard() {
        guard let images = NSPasteboard.general.readObjects(forClasses: [NSImage.self]) as? [NSImage],
              !images.isEmpty else { return }
        start(images)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        var collected: [NSImage] = []
        let group = DispatchGroup()
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                handled = true
                group.enter()
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    defer { group.leave() }
                    var url: URL?
                    if let direct = item as? URL { url = direct }
                    else if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
                    if let url, let image = NSImage(contentsOf: url) {
                        collected.append(image)
                    }
                }
            } else if provider.canLoadObject(ofClass: NSImage.self) {
                handled = true
                group.enter()
                _ = provider.loadObject(ofClass: NSImage.self) { object, _ in
                    defer { group.leave() }
                    if let image = object as? NSImage { collected.append(image) }
                }
            }
        }
        group.notify(queue: .main) {
            if !collected.isEmpty { start(collected) }
        }
        return handled
    }

    private var pickStage: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "text.viewfinder")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(dropTargeted ? DS.accentText : DS.textTertiary)
            HStack(spacing: 10) {
                Button(tr("Choose images…")) { showFilePicker = true }
                    .buttonStyle(AccentButtonStyle())
                Button(tr("Paste from clipboard")) { pasteFromClipboard() }
                    .buttonStyle(GhostButtonStyle())
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(30)
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(dropTargeted ? DS.accent : DS.border,
                              style: StrokeStyle(lineWidth: 1.5, dash: [7, 5]))
                .padding(24)
        )
    }
}

// MARK: - Review stage

private struct OCRReviewStage: View {
    @Bindable var session: ScreenshotImportSession
    let onSave: () -> Void
    let onCancel: () -> Void

    private var includedWithValues: Int {
        session.holdings.filter { $0.include && (!$0.marketValue.isEmpty || (!$0.quantity.isEmpty && !$0.unitNAV.isEmpty)) }.count
    }

    private var closingCount: Int {
        let updated = session.matchedHoldingIDs
        return session.missing.filter { $0.close && !updated.contains($0.id) }.count
    }

    private var flaggedCount: Int {
        session.holdings.filter { $0.include && !$0.flaggedFields.isEmpty }.count
    }

    var body: some View {
        HStack(spacing: 0) {
            // ── Screenshot with detection overlay ─────────────────────────
            VStack(spacing: 8) {
                ScreenshotPane(image: session.images[min(session.currentImageIndex, session.images.count - 1)],
                               boxes: session.showBoxes ? session.holdings.filter(\.include).map(\.sourceBox) : [])
                HStack {
                    if session.images.count > 1 {
                        CapsuleSwitch(options: Array(0..<session.images.count),
                                      selection: $session.currentImageIndex) { trf("Image %d", $0 + 1) }
                    }
                    Toggle(tr("Show detections"), isOn: $session.showBoxes)
                        .toggleStyle(LimeCheckboxStyle())
                        .font(DS.caption)
                        .foregroundStyle(DS.textSecondary)
                    Spacer()
                }
                .padding(.horizontal, 4)
            }
            .padding(14)
            .frame(width: 420)

            Divider().overlay(DS.border)

            // ── Editable results ─────────────────────────────────────────
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    DatePicker(tr("Valuation date"), selection: $session.valuationDate, displayedComponents: .date)
                        .frame(width: 210)
                    Spacer()
                }
                .font(DS.caption)
                .padding(12)

                if flaggedCount > 0 {
                    IssueBanner(issue: DataQualityIssue(
                        severity: .warning, icon: "eye.trianglebadge.exclamationmark",
                        message: tr("Low-confidence fields (amber) — verify against the screenshot before saving.")))
                        .padding(.horizontal, 12)
                        .padding(.bottom, 6)
                }

                Divider().overlay(DS.border)

                ScrollView {
                    VStack(spacing: 10) {
                        if !session.accountTotalText.isEmpty {
                            HStack(spacing: 8) {
                                Image(systemName: "sum")
                                    .font(.system(size: 13.5))
                                    .foregroundStyle(DS.finBlue)
                                Text(tr("Account total detected:"))
                                    .font(DS.caption)
                                    .foregroundStyle(DS.textSecondary)
                                Text("\(Fmt.symbol(for: session.accountTotalCurrency))\(session.accountTotalText)")
                                    .font(DS.moneySmall)
                                    .foregroundStyle(DS.textPrimary)
                                if let checksum = session.checksum {
                                    if checksum.matches {
                                        Label(tr("matches the rows"), systemImage: "checkmark.circle.fill")
                                            .font(DS.caption)
                                            .foregroundStyle(DS.positive)
                                    } else {
                                        Label(trf("rows add up to %@ — a row may be missing or misread",
                                                  Fmt.money(checksum.rowsSum, session.accountTotalCurrency)),
                                              systemImage: "exclamationmark.triangle.fill")
                                            .font(DS.caption)
                                            .foregroundStyle(DS.warning)
                                            .lineLimit(2)
                                    }
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 4)
                        }
                        ForEach($session.holdings) { $holding in
                            DraftCard(holding: $holding)
                        }
                        MissingHoldingsCard(session: session)
                        if session.holdings.isEmpty {
                            Text(tr("No holdings parsed — check the screenshot shows the holdings list."))
                                .font(DS.body)
                                .foregroundStyle(DS.textTertiary)
                                .padding(.top, 30)
                        }
                    }
                    .padding(12)
                }

                Divider().overlay(DS.border)
                HStack {
                    Spacer()
                    Button(tr("Cancel"), action: onCancel)
                        .buttonStyle(GhostButtonStyle())
                    Button(trf("Save %d holdings", includedWithValues), action: onSave)
                        .buttonStyle(AccentButtonStyle())
                        .disabled(includedWithValues == 0 && closingCount == 0)
                        .keyboardShortcut(.defaultAction)
                }
                .padding(12)
            }
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Screenshot pane with Vision-box overlay

private struct ScreenshotPane: View {
    let image: NSImage
    let boxes: [CGRect]

    var body: some View {
        GeometryReader { geo in
            let fitted = fittedRect(imageSize: image.size, in: geo.size)
            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.25)
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: geo.size.width, height: geo.size.height)
                ForEach(Array(boxes.enumerated()), id: \.offset) { _, box in
                    RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(DS.accent.opacity(0.85), lineWidth: 1.2)
                        .background(RoundedRectangle(cornerRadius: 3).fill(DS.accent.opacity(0.07)))
                        .frame(width: max(4, box.width * fitted.width),
                               height: max(4, box.height * fitted.height))
                        .offset(x: fitted.minX + box.minX * fitted.width,
                                y: fitted.minY + (1 - box.maxY) * fitted.height)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(DS.border, lineWidth: 1))
    }

    private func fittedRect(imageSize: CGSize, in container: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let scale = min(container.width / imageSize.width, container.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(x: (container.width - size.width) / 2,
                      y: (container.height - size.height) / 2,
                      width: size.width, height: size.height)
    }
}

// MARK: - Holdings the screenshots don't show
//
// A fund that was sold simply disappears from the next screenshot. Without
// an explicit answer it would stay on the board at its last value forever,
// so the review asks: still held (screenshot was partial), or sold?

private struct MissingHoldingsCard: View {
    @Bindable var session: ScreenshotImportSession

    var body: some View {
        let updated = session.matchedHoldingIDs
        if session.missing.contains(where: { !updated.contains($0.id) }) {
            VStack(alignment: .leading, spacing: 8) {
                Text(tr("Not in this screenshot"))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(DS.textPrimary)
                Text(tr("Tick the ones you no longer hold. They are marked as sold on the valuation date; their history is kept."))
                    .font(.system(size: 12))
                    .foregroundStyle(DS.textTertiary)
                ForEach($session.missing) { $item in
                    if !updated.contains(item.id) {
                        HStack(spacing: 8) {
                            Toggle("", isOn: $item.close)
                                .toggleStyle(LimeCheckboxStyle())
                                .labelsHidden()
                            Text(item.label)
                                .font(DS.body)
                                .foregroundStyle(DS.textPrimary)
                                .lineLimit(1)
                            Spacer()
                            Text(item.lastValue)
                                .font(DS.moneySmall)
                                .foregroundStyle(DS.textSecondary)
                        }
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DS.bgSecondary)
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(DS.border, lineWidth: 1))
        }
    }
}

// MARK: - Editable draft card

private struct DraftCard: View {
    @Binding var holding: ScreenshotImportSession.EditableHolding

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Toggle("", isOn: $holding.include)
                    .toggleStyle(LimeCheckboxStyle())
                    .labelsHidden()
                TextField(holding.platform == .binance ? tr("Asset name") : tr("Fund name"), text: $holding.name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(DS.textPrimary)
                flaggedIcon("name")
                TextField(tr("Code"), text: $holding.code)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13.5).monospacedDigit())
                    .foregroundStyle(DS.textSecondary)
                    .frame(width: 64)
                Spacer()
                if let reason = holding.excludedReason {
                    Text(reason)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(DS.textSecondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2.5)
                        .background(DS.textSecondary.opacity(0.12))
                        .clipShape(Capsule())
                        .help("Stablecoins are cash, not positions — tick the box to import anyway")
                }
                if let matched = holding.matchedLabel {
                    chip(icon: "link",
                         text: "\(tr(holding.reopens ? "reopens" : "updates")) \(matched)",
                         color: DS.finBlue)
                        .help(tr("Matched an existing holding — this valuation will be added to it"))
                } else {
                    if let suggested = holding.suggestedLabel {
                        Button {
                            holding.matchedHoldingID = holding.suggestedHoldingID
                            holding.matchedLabel = suggested
                            holding.suggestedHoldingID = nil
                            holding.suggestedLabel = nil
                        } label: {
                            chip(icon: "questionmark.circle", text: trf("Same as %@?", suggested), color: DS.warning)
                        }
                        .buttonStyle(.plain)
                        .help(tr("Similar name, not identical. Click to update that holding instead of adding a new one."))
                    }
                    Text(tr("new"))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(DS.positive)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2.5)
                        .background(DS.positive.opacity(0.12))
                        .clipShape(Capsule())
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                let sym = holding.currencySymbol
                if holding.platform == .binance {
                    fieldEditor("value \(sym)", $holding.marketValue, key: "marketValue")
                    fieldEditor("PNL \(sym)", $holding.profit, key: "profit")
                    fieldEditor("total cost \(sym)", $holding.costBasis, key: "costBasis")
                    fieldEditor("amount", $holding.quantity, key: "quantity")
                    fieldEditor("price \(sym)", $holding.unitNAV, key: "unitNAV")
                    fieldEditor("return %", $holding.returnRatePercent, key: "returnRatePercent")
                } else {
                    fieldEditor("持有金额 · value \(sym)", $holding.marketValue, key: "marketValue")
                    fieldEditor("持有收益 · profit \(sym)", $holding.profit, key: "profit")
                    fieldEditor("收益率 · return %", $holding.returnRatePercent, key: "returnRatePercent")
                    fieldEditor("份额 · units", $holding.quantity, key: "quantity")
                    fieldEditor("净值 · NAV", $holding.unitNAV, key: "unitNAV")
                    fieldEditor("成本 · cost \(sym)", $holding.costBasis, key: "costBasis")
                }
            }
        }
        .padding(12)
        .background(DS.bgSecondary)
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(DS.border, lineWidth: 1))
        .opacity(holding.include ? 1 : 0.45)
    }

    private func chip(icon: String, text: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 11))
            Text(text)
                .font(.system(size: 12))
                .lineLimit(1)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 7)
        .padding(.vertical, 2.5)
        .background(color.opacity(0.12))
        .clipShape(Capsule())
    }

    @ViewBuilder
    private func flaggedIcon(_ key: String) -> some View {
        if holding.flaggedFields.contains(key) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11.5))
                .foregroundStyle(DS.warning)
                .help("Low OCR confidence — verify against the screenshot")
        }
    }

    private func fieldEditor(_ label: String, _ text: Binding<String>, key: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(label)
                    .font(.system(size: 12))
                    .foregroundStyle(DS.textTertiary)
                flaggedIcon(key)
            }
            TextField("—", text: text)
                .textFieldStyle(.plain)
                .font(DS.moneySmall)
                .foregroundStyle(DS.textPrimary)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(DS.bgElevated)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(holding.flaggedFields.contains(key) ? DS.warning.opacity(0.7) : .clear, lineWidth: 1)
                )
        }
    }
}
