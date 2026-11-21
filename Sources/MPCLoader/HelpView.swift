import SwiftUI
import AppKit

/// Which help page is showing. Shared so the menu, the About window and links can open a page.
@MainActor
final class HelpNavigator: ObservableObject {
    @Published var selection: String? = HelpContent.firstTopic

    func show(_ topic: String) {
        if HelpContent.topic(topic) != nil { selection = topic }
    }
}

/// The help window: topics down the side, searchable, with the chosen page on the right.
struct HelpView: View {
    static let windowTitle = "MPC Loader Help"

    @EnvironmentObject private var navigator: HelpNavigator
    @State private var query = ""

    private var results: [HelpTopic] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return HelpContent.topics }
        let words = needle.split(separator: " ").map(String.init)
        return HelpContent.topics.filter { topic in words.allSatisfy { topic.searchText.contains($0) } }
    }

    var body: some View {
        NavigationSplitView {
            List(results, selection: $navigator.selection) { topic in
                Label(topic.title, systemImage: topic.symbol)
                    .tag(topic.id)
            }
            .overlay {
                if results.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 300)
        } detail: {
            if let topic = HelpContent.topic(navigator.selection) {
                HelpPage(topic: topic)
                    .id(topic.id)
            } else {
                ContentUnavailableView("Choose a Topic", systemImage: "questionmark.circle",
                                       description: Text("Pick a topic on the left, or search for what you need."))
            }
        }
        .searchable(text: $query, placement: .sidebar, prompt: "Search Help")
        .onChange(of: query) { _, _ in
            // Searching shows the best match straight away.
            if let first = results.first, !results.contains(where: { $0.id == navigator.selection }) {
                navigator.selection = first.id
            }
        }
        // Links between help pages are written as help:topic-id.
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme == "help" else { return .systemAction }
            navigator.show(String(url.absoluteString.dropFirst("help:".count)))
            return .handled
        })
        .navigationTitle(HelpView.windowTitle)
        .frame(minWidth: 720, minHeight: 460)
    }
}

/// One help page.
private struct HelpPage: View {
    let topic: HelpTopic

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Label {
                    Text(topic.title)
                } icon: {
                    Image(systemName: topic.symbol)
                        .foregroundStyle(.tint)
                }
                .font(.largeTitle.weight(.bold))
                .padding(.bottom, 2)

                Text(topic.summary)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 6)

                ForEach(Array(topic.blocks.enumerated()), id: \.offset) { _, block in
                    HelpBlockView(block: block)
                }
            }
            .textSelection(.enabled)
            .frame(maxWidth: 660, alignment: .leading)
            .padding(.horizontal, 36)
            .padding(.vertical, 30)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}

private struct HelpBlockView: View {
    let block: HelpBlock

    var body: some View {
        switch block {
        case .heading(let title):
            Text(rich(title))
                .font(.title2.weight(.semibold))
                .padding(.top, 10)

        case .text(let body):
            Text(rich(body))
                .fixedSize(horizontal: false, vertical: true)

        case .steps(let steps):
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("\(index + 1)")
                            .font(.callout.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.white)
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(Color.accentColor))
                            .accessibilityLabel("Step \(index + 1)")
                        Text(rich(step))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

        case .bullets(let items):
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•")
                            .foregroundStyle(.secondary)
                        Text(rich(item))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

        case .shortcuts(let shortcuts):
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 20, verticalSpacing: 8) {
                ForEach(Array(shortcuts.enumerated()), id: \.offset) { _, shortcut in
                    GridRow {
                        Text(shortcut.keys)
                            .font(.body.monospaced())
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                            .gridColumnAlignment(.trailing)
                        Text(shortcut.action)
                    }
                }
            }

        case .note(let body):
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(.tint)
                Text(rich(body))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            .padding(.top, 6)
        }
    }

    /// Help text may use **bold** and [links](help:topic).
    private func rich(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}
