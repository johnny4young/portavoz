import Foundation
import PortavozCore
import SwiftUI

/// Private aggregate feedback about generated commitment suggestions. This
/// surface is advisory: it cannot alter candidates, reminders, or commitments.
struct CommitmentFieldQualityView: View {
    let model: CommitmentRadarModel

    private var state: CommitmentRadarModel.State { model.state }

    @ViewBuilder
    var body: some View {
        switch state.qualityPhase {
        case .idle, .loading:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Loading private quality signals…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 180)
        case .failed:
            ContentUnavailableView {
                Label("Couldn’t load quality signals", systemImage: "exclamationmark.triangle")
            } description: {
                Text("Your reviews are still safe on this Mac.")
            } actions: {
                Button("Try again") {
                    Task { await model.send(.load) }
                }
                .accessibilityIdentifier("commitment-quality-retry")
            }
        case .empty:
            ContentUnavailableView {
                Label("No quality history yet", systemImage: "chart.bar.xaxis")
            } description: {
                Text("Review generated suggestions to build a private 90-day signal.")
            }
            .accessibilityIdentifier("commitment-quality-empty")
        case .loaded:
            if let scorecard = state.qualityScorecard {
                scorecardView(scorecard)
            }
        }
    }
}

private extension CommitmentFieldQualityView {
    func scorecardView(_ scorecard: CommitmentFieldQualityScorecard) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            qualityNotice
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 170), spacing: 12)],
                alignment: .leading,
                spacing: 12
            ) {
                metricCard(
                    title: "Suggestions kept",
                    value: percent(keptRate(scorecard.overall)),
                    detail: reviewedDetail(scorecard.overall),
                    identifier: "commitment-quality-kept")
                metricCard(
                    title: "Owner accuracy",
                    value: percent(scorecard.overall.ownerPrecision),
                    detail: ownerDetail(scorecard.overall),
                    identifier: "commitment-quality-owner")
                metricCard(
                    title: "Evidence coverage",
                    value: percent(scorecard.overall.evidenceCoverage),
                    detail: evidenceDetail(scorecard.overall),
                    identifier: "commitment-quality-evidence")
                metricCard(
                    title: "Median time to confirm",
                    value: duration(scorecard.overall.confirmationLatencyP50),
                    detail: latencyDetail(scorecard.overall),
                    identifier: "commitment-quality-latency")
            }
            .accessibilityElement(children: .contain)
            observationSummary(scorecard.overall)
            languageBreakdown(scorecard.byLanguage)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("commitment-quality-scorecard")
    }

    var qualityNotice: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Private quality check", systemImage: "lock.shield.fill")
                .font(.headline)
            Text("Rolling 90-day evidence from suggestions you actually reviewed.")
                .foregroundStyle(.secondary)
            Label("Advisory only — no threshold or automation uses these numbers.",
                  systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(PVDesign.accent)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PVDesign.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "Advisory only — no threshold or automation uses these numbers.")
        .accessibilityIdentifier("commitment-quality-advisory")
    }

    func metricCard(
        title: LocalizedStringKey,
        value: String,
        detail: String,
        identifier: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(verbatim: value)
                .font(.title2.bold())
                .monospacedDigit()
            Text(verbatim: detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier)
    }

    func observationSummary(_ metrics: CommitmentFieldQualityMetrics) -> some View {
        HStack(spacing: 14) {
            Label(
                L10n.format("%d presented", metrics.observationCount),
                systemImage: "rectangle.stack")
                .accessibilityIdentifier("commitment-quality-observed")
            Label(
                L10n.format("%d reviewed", metrics.terminalReviewCount),
                systemImage: "checkmark.circle")
            if metrics.pendingCount + metrics.deferredCount > 0 {
                Label(
                    L10n.format(
                        "%d awaiting review",
                        metrics.pendingCount + metrics.deferredCount),
                    systemImage: "clock")
            }
            if metrics.withdrawnCount > 0 {
                Label(
                    L10n.format("%d withdrawn", metrics.withdrawnCount),
                    systemImage: "arrow.uturn.backward")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    func languageBreakdown(
        _ breakdowns: [CommitmentFieldQualityBreakdown]
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("By spoken language")
                .font(.headline)
            ForEach(
                breakdowns.filter { $0.metrics.observationCount > 0 },
                id: \.language
            ) { breakdown in
                HStack(spacing: 12) {
                    Text(verbatim: languageName(breakdown.language))
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    Text(L10n.format(
                        "%d presented",
                        breakdown.metrics.observationCount))
                    Text(verbatim: languageReviewSummary(breakdown.metrics))
                        .frame(minWidth: 88, alignment: .trailing)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.vertical, 2)
                .accessibilityIdentifier(
                    "commitment-quality-language-\(breakdown.language.rawValue)")
            }
        }
        .padding(16)
        .background(.quaternary.opacity(0.32), in: RoundedRectangle(cornerRadius: 12))
    }
}

private extension CommitmentFieldQualityView {
    func keptRate(_ metrics: CommitmentFieldQualityMetrics) -> Double? {
        guard metrics.terminalReviewCount > 0 else { return nil }
        return Double(metrics.confirmedCount) / Double(metrics.terminalReviewCount)
    }

    func percent(_ value: Double?) -> String {
        guard let value else { return "—" }
        return L10n.format("%d%%", Int((value * 100).rounded()))
    }

    func duration(_ seconds: TimeInterval?) -> String {
        guard let seconds else { return "—" }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 86_400 ? [.day, .hour] : [.hour, .minute]
        formatter.maximumUnitCount = 1
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: max(0, seconds)) ?? "—"
    }

    func reviewedDetail(_ metrics: CommitmentFieldQualityMetrics) -> String {
        guard metrics.terminalReviewCount > 0 else {
            return L10n.text("Not measured yet")
        }
        return L10n.format(
            "%d of %d reviewed suggestions",
            metrics.confirmedCount,
            metrics.terminalReviewCount)
    }

    func ownerDetail(_ metrics: CommitmentFieldQualityMetrics) -> String {
        guard metrics.ownerClaimCount > 0 else {
            return L10n.text("No owner suggestions measured")
        }
        return L10n.format(
            "%d of %d owner suggestions",
            metrics.exactOwnerClaimCount,
            metrics.ownerClaimCount)
    }

    func evidenceDetail(_ metrics: CommitmentFieldQualityMetrics) -> String {
        guard metrics.confirmedCount > 0 else {
            return L10n.text("No confirmations measured")
        }
        return L10n.format(
            "%d of %d confirmations",
            metrics.evidenceCoveredConfirmationCount,
            metrics.confirmedCount)
    }

    func latencyDetail(_ metrics: CommitmentFieldQualityMetrics) -> String {
        metrics.confirmationLatencyCount > 0
            ? L10n.format("Across %d confirmations", metrics.confirmationLatencyCount)
            : L10n.text("No confirmations measured")
    }

    func languageName(_ language: CommitmentFieldQualityLanguage) -> String {
        switch language {
        case .english: L10n.text("English")
        case .spanish: L10n.text("Spanish")
        case .mixed: L10n.text("Mixed")
        case .otherOrUnknown: L10n.text("Other or unknown")
        }
    }

    func languageReviewSummary(_ metrics: CommitmentFieldQualityMetrics) -> String {
        guard let rate = keptRate(metrics) else {
            return L10n.text("Awaiting review")
        }
        return L10n.format("%@ kept", percent(rate))
    }
}
