import SwiftUI
import AppKit

/// The About window: the app's icon, name and version, with links to help and the project.
struct AboutView: View {
    static let windowTitle = "About MPC Loader"

    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var help: HelpNavigator

    static let projectURL = URL(string: "https://github.com/edfreed-makes/MPCLoader")!

    private var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        guard let short = info["CFBundleShortVersionString"] as? String else { return "Development build" }
        if let build = info["CFBundleVersion"] as? String, !build.isEmpty { return "Version \(short) (\(build))" }
        return "Version \(short)"
    }

    var body: some View {
        VStack(spacing: 0) {
            // The app's own icon, as macOS shows it in Finder and the Dock.
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 128, height: 128)
                .accessibilityLabel("MPC Loader icon")
                .padding(.bottom, 10)

            Text("MPC Loader")
                .font(.title.weight(.semibold))
            Text(version)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .padding(.top, 2)

            Text("Copy samples between your Mac and your Akai MPC over your home network.")
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 14)

            HStack(spacing: 10) {
                Button("MPC Loader Help") {
                    help.show(HelpContent.firstTopic)
                    openWindow(id: "help")
                }
                Link("Project on GitHub", destination: AboutView.projectURL)
                    .buttonStyle(.bordered)
            }
            .padding(.top, 16)

            Divider()
                .padding(.vertical, 16)

            VStack(spacing: 4) {
                Text("Free software under the GNU General Public License, version 3.")
                Text("Not made or endorsed by Akai Professional or inMusic. Akai and MPC are their trademarks.")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 28)
        .padding(.top, 8)
        .padding(.bottom, 22)
        .frame(width: 380)
    }
}
