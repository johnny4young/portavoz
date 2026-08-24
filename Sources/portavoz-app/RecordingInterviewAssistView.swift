import ApplicationKit
import PortavozCore
import SwiftUI

/// Explicit, pull-only interview assistance inside an already visible active
/// recording. The panel never owns capture and never speaks or acts for the
/// user; it exposes the exact question and exact transcript citations.
struct RecordingInterviewAssistView: View {
    @Environment(AppServices.self) private var services
    @Bindable var controller: RecordingController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Text(L10n.text(
                "Uses only earlier finalized captions. It never starts, stops, or speaks for you."))
                .font(.caption2)
                .foregroundStyle(.secondary)
            if let context = controller.interviewAssist.context {
                currentQuestion(context.question)
                answerAction
                answerState
            } else {
                Label(
                    L10n.text("Waiting for a question from the other participants."),
                    systemImage: "waveform.badge.magnifyingglass")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("recording-interview-waiting")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            PVDesign.accent.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(PVDesign.accent.opacity(0.22))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("recording-interview-panel")
    }

    private var header: some View {
        HStack {
            Label(L10n.text("Interview assist"), systemImage: "person.crop.rectangle.stack")
                .font(.headline)
            Spacer()
            if controller.interviewAssist.answerState != nil {
                Button {
                    controller.interviewAssist.dismissAnswer()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.text("Dismiss interview answer"))
                .accessibilityIdentifier("recording-interview-answer-dismiss")
            }
        }
    }

    private func currentQuestion(_ question: InterviewQuestion) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(L10n.text("Current question"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(PVDesign.accent)
            Text(question.text)
                .font(.callout.weight(.medium))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("recording-interview-current-question")
        }
    }

    private var answerAction: some View {
        Button {
            controller.interviewAssist.requestAnswer(
                using: services.assistInterviewQuestion,
                isRecording: { [weak controller] in
                    controller?.phase == .recording
                })
        } label: {
            Label(L10n.text("Find grounded answer"), systemImage: "text.magnifyingglass")
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .disabled(controller.interviewAssist.answerState == .generating)
        .accessibilityIdentifier("recording-interview-answer")
        .accessibilityHint(L10n.text(
            "Drafts only from earlier cited captions using your selected local AI."))
    }

    @ViewBuilder
    private var answerState: some View {
        switch controller.interviewAssist.answerState {
        case nil:
            Text(L10n.text(
                "Ask only when the earlier conversation contains evidence. Otherwise Portavoz will abstain."))
                .font(.caption2)
                .foregroundStyle(.secondary)
        case .generating:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(L10n.text("Checking the cited conversation…"))
            }
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("recording-interview-generating")
        case .answered(let answer):
            groundedAnswer(answer)
        case .insufficientEvidence:
            status(
                "The earlier conversation does not contain enough cited evidence to answer.",
                identifier: "recording-interview-insufficient")
        case .unavailable:
            status(
                "Your selected local AI is unavailable. The recording continues untouched.",
                identifier: "recording-interview-unavailable")
        case .failed:
            status(
                "No answer this time. The recording and its captions remain untouched.",
                identifier: "recording-interview-failed")
        case .timedOut:
            status(
                "The answer took too long. Try again; the recording continues untouched.",
                identifier: "recording-interview-timeout")
        }
    }

    private func groundedAnswer(
        _ answer: InterviewGroundedAnswer
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(answer.text)
                .font(.callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("recording-interview-grounded-answer")
            ForEach(answer.citations) { citation in
                let source = citation.evidence
                VStack(alignment: .leading, spacing: 2) {
                    Text("[\(citation.number)] \(speakerLabel(source.channel)) · \(timestamp(source.timestamp))")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(PVDesign.accent)
                    Text(source.text)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(
                    "recording-interview-evidence-\(citation.number)")
            }
        }
    }

    private func status(
        _ key: String,
        identifier: String
    ) -> some View {
        Text(L10n.text(key))
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier(identifier)
    }

    private func speakerLabel(_ channel: AudioChannel) -> String {
        channel == .microphone ? L10n.text("You") : L10n.text("Others")
    }

    private func timestamp(_ seconds: TimeInterval) -> String {
        let value = max(0, Int(seconds.rounded()))
        return String(format: "%02d:%02d", value / 60, value % 60)
    }
}
