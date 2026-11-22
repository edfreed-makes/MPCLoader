import SwiftUI

/// The copies waiting their turn, listed above the status bar while there are any. The copy that is
/// running shows its progress in the status bar below.
struct CopyQueueStrip: View {
    @EnvironmentObject private var model: AppModel

    private let rowHeight: CGFloat = 26

    var body: some View {
        if !model.queue.isEmpty {
            VStack(spacing: 0) {
                header
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(model.queue.enumerated()), id: \.element.id) { index, item in
                            CopyQueueRow(item: item, isNext: index == 0)
                                .frame(height: rowHeight)
                        }
                    }
                }
                // Room for three at a time. Scroll for the rest.
                .frame(height: CGFloat(min(model.queue.count, 3)) * rowHeight)
                Divider()
            }
            .font(.callout)
            .background(.bar)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Copies waiting their turn")
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "list.bullet")
                .foregroundStyle(.secondary)
            Text("Waiting to copy")
                .fontWeight(.semibold)
            Text("\(model.queue.count)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Spacer()
            Button("Clear Queue") { model.clearQueue() }
                .buttonStyle(.link)
                .help("Remove every copy that hasn't started. The copy that is running carries on.")
        }
        .padding(.horizontal, 12)
        .frame(height: rowHeight)
    }
}

private struct CopyQueueRow: View {
    @EnvironmentObject private var model: AppModel
    let item: AppModel.QueuedCopy
    let isNext: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: item.toMPC ? "arrow.up.doc" : "arrow.down.doc")
                .foregroundStyle(.secondary)
                .frame(width: 16)
                .help(item.toMPC ? "Copy to the MPC" : "Copy to this Mac")
            Text(item.name)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)
            Text(item.toMPC ? "to “\(item.destination)” on the MPC" : "to “\(item.destination)” on this Mac")
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            status
            Button { model.removeFromQueue(item.id) } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Remove from the queue")
            .accessibilityLabel("Remove \(item.name) from the queue")
        }
        .padding(.horizontal, 12)
    }

    @ViewBuilder
    private var status: some View {
        switch item.stage {
        case .checking:
            if model.conflictOwner == item.id {
                Text("Waiting for your answer")
                    .foregroundStyle(.orange)
            } else {
                ProgressView()
                    .controlSize(.mini)
                Text("Checking the MPC…")
                    .foregroundStyle(.secondary)
            }
        case .waiting:
            Text(statusText)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    /// "Next", or "Replace · Waiting" when an answer about names already on the MPC was given.
    private var statusText: String {
        let turn = isNext ? "Next" : "Waiting"
        guard let answer = item.answer, !item.answeredNames.isEmpty else { return turn }
        switch answer {
        case .replace: return "Replace · \(turn)"
        case .keepBoth: return "Keep Both · \(turn)"
        case .skip: return "Skip existing · \(turn)"
        case .cancel: return turn
        }
    }
}
