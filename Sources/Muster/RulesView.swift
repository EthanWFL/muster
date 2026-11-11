import MusterCore
import SwiftUI

struct RulesView: View {
    @ObservedObject var rules: RulesModel

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            header
            if let message = rules.errorMessage {
                Text(message).font(.subheadline).foregroundStyle(.orange).padding(.horizontal, 12)
            }
            if rules.findings.isEmpty {
                VStack(spacing: 4) {
                    Text(rules.isScanning ? L10n.t("Scanning…") : rules.hasScanned ? L10n.t("No findings") : L10n.t("Not scanned yet"))
                        .fontWeight(.semibold)
                    Text(L10n.t("Duplicate rules, broken references and conflicts across your repos show up here"))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
                .padding(.horizontal, 16)
            } else {
                ForEach(rules.findings) { FindingRow(rules: rules, finding: $0) }
            }
        }
        .onAppear { rules.scanIfNeeded() }
    }

    private var header: some View {
        HStack {
            Text(summary).font(.subheadline).foregroundStyle(.secondary)
            Spacer()
            Button(L10n.t("Rescan")) { rules.scan() }
                .buttonStyle(PillButtonStyle(kind: .quiet))
                .disabled(rules.isScanning)
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
    }

    private var summary: String {
        if rules.isScanning { return L10n.t("Scanning %@…", rules.scanner.config.root.abbreviatedPath) }
        guard rules.hasScanned else { return rules.scanner.config.root.abbreviatedPath }
        let n = rules.findings.count
        let files = rules.scannedFiles
        if n == 1 {
            return L10n.t("1 finding in %d rule files", files)
        }
        return L10n.t("%d findings in %d rule files", n, files)
    }
}

private struct FindingRow: View {
    @ObservedObject var rules: RulesModel
    let finding: RuleFinding
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(L10n.t(finding.kind.rawValue))
                    .font(.subheadline).foregroundStyle(.secondary)
                    .frame(width: 64, alignment: .leading)
                Text(finding.title).lineLimit(2)
                Spacer(minLength: 8)
                Button(copied ? L10n.t("Copied") : L10n.t("Copy fix")) {
                    rules.copy(finding)
                    copied = true
                    Task {
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        copied = false
                    }
                }
                .buttonStyle(PillButtonStyle(kind: .quiet))
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(finding.locations, id: \.self) { location in
                    Button { RulesModel.open(location: location) } label: {
                        Text(location.abbreviatedPath)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                    .buttonStyle(.plain)
                    .help(L10n.t("Open the file"))
                }
            }
            .padding(.leading, 72)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

private extension String {
    var abbreviatedPath: String { (self as NSString).abbreviatingWithTildeInPath }
}
