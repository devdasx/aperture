import SwiftUI
import UIKit

struct ApertureErrorReport: Identifiable, Equatable, Sendable {
    static let supportEmail = "care@aperturex.io"

    let id = UUID()
    let context: String
    let title: String
    let message: String
    let technicalDetails: String
    let recoverySuggestion: String?
    let metadata: [String: String]
    let createdAt: Date

    init(
        context: String,
        title: String,
        message: String,
        error: Error,
        recoverySuggestion: String? = nil,
        metadata: [String: String] = [:],
        createdAt: Date = Date()
    ) {
        self.context = context
        self.title = title
        self.message = message
        self.technicalDetails = Self.describe(error)
        self.recoverySuggestion = recoverySuggestion
        self.metadata = metadata
        self.createdAt = createdAt
    }

    var supportMailURL: URL? {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = Self.supportEmail
        components.queryItems = [
            URLQueryItem(name: "subject", value: "Aperture error: \(context)"),
            URLQueryItem(name: "body", value: supportBody)
        ]
        return components.url
    }

    var supportBody: String {
        var lines: [String] = [
            "Aperture error report",
            "",
            "Context: \(context)",
            "Title: \(title)",
            "Message: \(message)",
            "Created: \(Self.formatTimestamp(createdAt))"
        ]
        if let recoverySuggestion, !recoverySuggestion.isEmpty {
            lines.append("Suggestion: \(recoverySuggestion)")
        }
        if !metadata.isEmpty {
            lines.append("")
            lines.append("Metadata:")
            for key in metadata.keys.sorted() {
                lines.append("- \(key): \(metadata[key] ?? "")")
            }
        }
        lines.append("")
        lines.append("Advanced sandbox:")
        lines.append(technicalDetails)
        return lines.joined(separator: "\n")
    }

    private static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        var lines: [String] = [
            "Type: \(String(reflecting: Swift.type(of: error)))",
            "Domain: \(nsError.domain)",
            "Code: \(nsError.code)",
            "Localized: \(error.localizedDescription)",
            "Description: \(String(describing: error))"
        ]
        if let localizedError = error as? LocalizedError {
            if let failureReason = localizedError.failureReason {
                lines.append("Failure reason: \(failureReason)")
            }
            if let recoverySuggestion = localizedError.recoverySuggestion {
                lines.append("Recovery suggestion: \(recoverySuggestion)")
            }
            if let helpAnchor = localizedError.helpAnchor {
                lines.append("Help anchor: \(helpAnchor)")
            }
        }
        if !nsError.userInfo.isEmpty {
            lines.append("User info:")
            for key in nsError.userInfo.keys.sorted(by: { "\($0)" < "\($1)" }) {
                lines.append("- \(key): \(String(describing: nsError.userInfo[key] ?? ""))")
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func formatTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

struct ApertureErrorSupportSection: View {
    let report: ApertureErrorReport

    @Environment(\.openURL) private var openURL
    @State private var isExpanded = false
    @State private var didCopy = false

    var body: some View {
        UniCard(stroke: UniColors.Feedback.Error.stroke.opacity(0.45)) {
            VStack(alignment: .leading, spacing: UniSpacing.m) {
                VStack(alignment: .leading, spacing: UniSpacing.xs) {
                    Label {
                        Text("Advanced sandbox")
                            .font(UniTypography.callout.weight(.semibold))
                            .foregroundStyle(UniColors.Text.primary)
                    } icon: {
                        Image(systemName: "wrench.and.screwdriver")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(UniColors.Feedback.Error.foreground)
                    }
                    Text("These details help diagnose what happened on this iPhone. They are not sent unless you choose to email support.")
                        .font(UniTypography.footnote)
                        .foregroundStyle(UniColors.Text.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                DisclosureGroup(isExpanded: $isExpanded) {
                    ScrollView(.vertical) {
                        Text(verbatim: report.supportBody)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(UniColors.Text.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(UniSpacing.s)
                    }
                    .frame(maxHeight: 360)
                    .scrollIndicators(.visible)
                    .background(
                        RoundedRectangle(cornerRadius: UniRadius.row, style: .continuous)
                            .fill(UniColors.Fill.quaternary)
                    )
                    .padding(.top, UniSpacing.xs)
                } label: {
                    Text("Show details")
                        .font(UniTypography.callout)
                        .foregroundStyle(UniColors.Text.primary)
                }

                HStack(spacing: UniSpacing.s) {
                    UniButton(
                        verbatim: didCopy ? "Copied" : "Copy details",
                        variant: .secondary,
                        tint: didCopy ? UniColors.Feedback.Success.foreground : nil
                    ) {
                        UIPasteboard.general.string = report.supportBody
                        didCopy = true
                    }
                    UniButton(title: "Email support", variant: .primary, systemImage: "envelope") {
                        if let url = report.supportMailURL {
                            openURL(url)
                        }
                    }
                }
            }
        }
    }
}

struct ApertureErrorReportSheet: View {
    let report: ApertureErrorReport

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: UniSpacing.l) {
                    VStack(alignment: .leading, spacing: UniSpacing.s) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 42, weight: .regular))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(UniColors.Feedback.Error.foreground)
                            .accessibilityHidden(true)
                        Text(verbatim: report.title)
                            .font(UniTypography.title1)
                            .foregroundStyle(UniColors.Text.primary)
                        Text(verbatim: report.message)
                            .font(UniTypography.body)
                            .foregroundStyle(UniColors.Text.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ApertureErrorSupportSection(report: report)
                }
                .padding(.horizontal, UniSpacing.l)
                .padding(.top, UniSpacing.m)
                .padding(.bottom, UniSpacing.xxl)
            }
            .background(UniColors.Background.primary)
            .navigationTitle("Error details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .tint(UniColors.Button.text)
                }
            }
        }
        .presentationBackground(UniColors.Background.primary)
    }
}
