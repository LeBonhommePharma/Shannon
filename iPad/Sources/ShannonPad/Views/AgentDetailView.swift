import Charts
import SwiftUI
import ShannonCore
import ShannonTheme

/// The centre column when one agent is selected: the same facts as the card,
/// given room to be read rather than glanced at.
struct AgentDetailView: View {
    @ObservedObject var hub: AgentHubViewModel
    var agent: AgentState
    var onAnnotate: (AnnotationTarget) -> Void

    private var series: [MetricSample] { hub.entropySeries(for: agent.id) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ShannonSpacing.md) {
                header

                if let question = hub.confirmation(forAgent: agent.id) {
                    blockedPrompt(question)
                } else if agent.activity == .blocked {
                    // Blocked with no synced question: the Mac has not
                    // published one (yet), and answering blind would be worse
                    // than saying so.
                    Label("Blocked — no question published", systemImage: "questionmark.circle")
                        .shannonText(.shannonCaption, color: .shannonWarning)
                }

                statsGrid
                entropySection
                linkSection
            }
            .padding(ShannonSpacing.md)
        }
        .background(Color.shannonBackground)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: ShannonSpacing.sm) {
            HStack(spacing: ShannonSpacing.sm) {
                Image(systemName: agent.activity.symbolName)
                    .font(.title2)
                    .foregroundStyle(agent.activity.tint)
                Text(agent.name)
                    .shannonText(.shannonLargeTitle)
                Spacer()
                Button {
                    onAnnotate(.agent(agent.id, agent.name))
                } label: {
                    Label("Annotate", systemImage: "pencil.tip.crop.circle")
                }
                .buttonStyle(.bordered)
            }

            Text(agent.taskTitle.isEmpty ? "No task" : agent.taskTitle)
                .shannonText(.shannonBody, color: .shannonSecondary)

            Text(agent.id)
                .shannonNumeric(color: .shannonTertiary)
        }
        .shannonCard()
    }

    private func blockedPrompt(_ question: PendingConfirmation) -> some View {
        VStack(alignment: .leading, spacing: ShannonSpacing.sm) {
            Label("Waiting on you", systemImage: "questionmark.circle.fill")
                .shannonText(.shannonHeadline, color: .shannonWarning)
            Text(question.question)
                .shannonText(.shannonBody)
            if !question.detail.isEmpty {
                Text(question.detail)
                    .shannonText(.shannonCaption, color: .shannonSecondary)
            }

            HStack(spacing: ShannonSpacing.sm) {
                Button {
                    hub.answer(question, approved: true)
                } label: {
                    Label("Confirm", systemImage: "checkmark")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .tint(.shannonSuccess)

                Button {
                    hub.answer(question, approved: false)
                } label: {
                    Label("Deny", systemImage: "xmark")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .tint(.shannonError)
            }
        }
        .shannonCard(isHighlighted: true)
    }

    private var statsGrid: some View {
        HStack(spacing: ShannonSpacing.md) {
            stat("Turns", "\(agent.turnCount)", tint: .shannonPrimary)
            stat("Entropy", agent.entropyBits.map { String(format: "%.2f", $0) } ?? "—",
                 tint: agent.isCollapsed ? .shannonError : .shannonPrimary)
            stat("Delta", agent.entropyDelta.map { String(format: "%+.2f", $0) } ?? "—",
                 tint: (agent.entropyDelta ?? 0) < 0 ? .shannonWarning : .shannonSecondary)
            stat("Updated", agent.updatedAt.formatted(date: .omitted, time: .shortened),
                 tint: .shannonSecondary)
        }
    }

    private func stat(_ name: String, _ value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: ShannonSpacing.xs) {
            Text(name.uppercased())
                .font(.shannonCaption)
                .tracking(0.8)
                .foregroundStyle(Color.shannonTertiary)
            Text(value)
                .font(.system(.title3, design: .monospaced, weight: .medium))
                .foregroundStyle(tint)
        }
        .shannonCard()
    }

    private var entropySection: some View {
        VStack(alignment: .leading, spacing: ShannonSpacing.sm) {
            Label("Entropy H", systemImage: "waveform.path.ecg")
                .shannonText(.shannonHeadline, color: .shannonAccent)

            if series.count > 1 {
                Chart(series) { sample in
                    AreaMark(x: .value("Time", sample.date), y: .value("H", sample.value))
                        .foregroundStyle(
                            .linearGradient(
                                colors: [
                                    agent.activity.tint.opacity(0.30),
                                    agent.activity.tint.opacity(0.02),
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                    LineMark(x: .value("Time", sample.date), y: .value("H", sample.value))
                        .foregroundStyle(agent.activity.tint)
                        .interpolationMethod(.monotone)
                }
                .chartYAxis { AxisMarks(position: .leading) }
                .frame(height: 200)
            } else {
                Text("Collecting samples — the trace needs two readings.")
                    .shannonText(.shannonCaption, color: .shannonSecondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            }
        }
        .shannonCard()
    }

    private var linkSection: some View {
        let upstream = hub.upstream(of: agent.id).compactMap { id in
            hub.snapshot.agents.first { $0.id == id }
        }
        let downstream = hub.links
            .filter { $0.sourceID == agent.id }
            .compactMap { link in hub.snapshot.agents.first { $0.id == link.targetID } }

        return VStack(alignment: .leading, spacing: ShannonSpacing.sm) {
            Label("Connections", systemImage: "arrow.triangle.branch")
                .shannonText(.shannonHeadline, color: .shannonAccent)

            if upstream.isEmpty, downstream.isEmpty {
                Text("Drag another agent onto this one to feed its output in.")
                    .shannonText(.shannonCaption, color: .shannonSecondary)
            }

            ForEach(upstream) { source in
                Label("\(source.name) → \(agent.name)", systemImage: "arrow.right")
                    .shannonText(.shannonCallout)
            }
            ForEach(downstream) { target in
                Label("\(agent.name) → \(target.name)", systemImage: "arrow.right")
                    .shannonText(.shannonCallout)
            }

            if !upstream.isEmpty || !downstream.isEmpty {
                Button("Remove All Connections") { hub.removeLinks(touching: agent.id) }
                    .font(.shannonCaption)
                    .foregroundStyle(Color.shannonError)
                    .buttonStyle(.plain)
            }
        }
        .shannonCard()
    }
}

/// The centre column when a benchmark is selected. The target list is the
/// completed/remaining split the Mac reports; per-target results are not synced,
/// so the rows show position rather than inventing RMSDs.
struct DockingDetailView: View {
    @ObservedObject var hub: AgentHubViewModel
    var progress: DockingProgress
    var onAnnotate: (AnnotationTarget) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ShannonSpacing.md) {
                DockingProgressView(
                    progress: progress,
                    rmsdSeries: hub.rmsdSeries(for: progress.id),
                    isSelected: false,
                    onSelect: {},
                    onAnnotateROI: { onAnnotate(.dockingROI(progress.id)) },
                    onCancel: {},
                    onViewTargets: {},
                    onExportCSV: {}
                )

                VStack(alignment: .leading, spacing: ShannonSpacing.sm) {
                    Label("Targets", systemImage: "list.bullet")
                        .shannonText(.shannonHeadline, color: .shannonAccent)

                    ForEach(0..<max(progress.targetsTotal, 0), id: \.self) { index in
                        targetRow(index)
                    }
                }
                .shannonCard()
            }
            .padding(ShannonSpacing.md)
        }
        .background(Color.shannonBackground)
    }

    private func targetRow(_ index: Int) -> some View {
        let done = index < progress.targetsComplete
        let isCurrent = index == progress.targetsComplete
        return HStack(spacing: ShannonSpacing.sm) {
            Image(systemName: done ? "checkmark.circle.fill"
                  : isCurrent ? "circle.dotted" : "circle")
                .foregroundStyle(done ? Color.shannonSuccess
                                 : isCurrent ? Color.shannonAccent : Color.shannonTertiary)
            Text(isCurrent && !progress.currentTarget.isEmpty
                 ? progress.currentTarget.uppercased()
                 : "target \(index + 1)")
                .shannonNumeric(color: isCurrent ? .shannonPrimary : .shannonSecondary)
            Spacer()
        }
        .padding(.vertical, 2)
    }
}
