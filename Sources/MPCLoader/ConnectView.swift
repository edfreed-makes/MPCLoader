import SwiftUI
import MPCKit

/// The screen shown until the app is connected: the MPC's address, the login, and help when it fails.
struct ConnectView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showLogin = false
    @FocusState private var addressFocused: Bool

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                header
                addressBox
                loginBox
                connectRow
                if let problem = model.problem {
                    ProblemPanel(problem: problem)
                }
            }
            .frame(maxWidth: 520)
            .padding(.horizontal, 32)
            .padding(.vertical, 36)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            showLogin = !model.usesDefaultLogin
            addressFocused = model.host.isEmpty
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: "square.grid.3x3.fill")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text("Connect to Your MPC")
                .font(.title2.weight(.semibold))
            Text("The MPC needs to be in developer mode and on the same network as this Mac.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var addressBox: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text("MPC address")
                    TextField("For example 192.168.1.50", text: $model.host)
                        .textFieldStyle(.roundedBorder)
                        .focused($addressFocused)
                        .disabled(model.state != .disconnected)
                        .onSubmit { model.connect() }
                    Button("Find MPC") { model.findMPC() }
                        .disabled(model.state != .disconnected || model.search == .searching)
                        .help("Search this network for an MPC in developer mode")
                }
                searchStatus
            }
            .padding(6)
        }
    }

    @ViewBuilder
    private var searchStatus: some View {
        switch model.search {
        case .idle:
            Text("Find MPC searches your network and fills in the address for you.")
                .font(.callout)
                .foregroundStyle(.secondary)
        case .searching:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Searching your network…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        case .nothing:
            Text("No MPC found. Check that it is switched on, in developer mode and on this network. If macOS asked whether MPC Loader may find devices on your local network, allow it and search again.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .found(let devices):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(devices) { device in
                    HStack(spacing: 6) {
                        Image(systemName: device.isMPC ? "checkmark.circle.fill" : "questionmark.circle")
                            .foregroundStyle(device.isMPC ? Color.green : Color.secondary)
                        Text(device.label)
                            .font(.callout)
                        if device.address != model.host.trimmingCharacters(in: .whitespaces) {
                            Button("Use") { model.use(device) }
                                .buttonStyle(.link)
                                .disabled(model.state != .disconnected)
                        }
                    }
                }
                if !devices.contains(where: \.isMPC) {
                    Text("None of these identified itself as an MPC with the standard login. If you have set a password on your MPC, enter its address and password yourself.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var loginBox: some View {
        GroupBox {
            DisclosureGroup(isExpanded: $showLogin) {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                    GridRow {
                        Text("User name")
                            .gridColumnAlignment(.trailing)
                        TextField(SSHSession.Settings.defaultUser, text: $model.user)
                            .textFieldStyle(.roundedBorder)
                    }
                    GridRow {
                        Text("Password")
                        SecureField("None", text: $model.password)
                            .textFieldStyle(.roundedBorder)
                    }
                    GridRow {
                        Text("Port")
                        HStack {
                            TextField(String(SSHSession.Settings.defaultPort), text: $model.portText)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 80)
                            Spacer()
                            Button("Use MPC Defaults") { model.resetLoginToDefaults() }
                                .disabled(model.usesDefaultLogin)
                        }
                    }
                }
                .disabled(model.state != .disconnected)
                .padding(.top, 8)
                Text("A password you enter is kept in your Mac's Keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 2)
            } label: {
                HStack {
                    Text("Login Details")
                    Spacer()
                    Text(model.usesDefaultLogin ? "Standard MPC login (root, no password)" : "Custom login")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(6)
        }
    }

    private var connectRow: some View {
        HStack {
            if model.state == .connecting {
                ProgressView()
                    .controlSize(.small)
                Text("Connecting…")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.state == .connecting {
                Button("Cancel") { model.cancelConnecting() }
                    .controlSize(.large)
            } else {
                Button("Connect") { model.connect() }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
            }
        }
    }
}

/// What went wrong and what to do about it. For "developer mode is off" it lists the steps.
private struct ProblemPanel: View {
    @EnvironmentObject private var model: AppModel
    let problem: AppModel.Problem

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Label {
                    Text(problem.title)
                        .font(.headline)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                }
                Text(problem.message)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if problem.showsDeveloperModeHelp {
                    Divider()
                    Text("To switch on developer mode")
                        .font(.subheadline.weight(.semibold))
                    ForEach(Array(DeveloperModeHelp.steps.enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("\(index + 1).")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                            Text(step)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Text(DeveloperModeHelp.footnote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                if problem.offersConnectAnyway {
                    Button("Connect Anyway") { model.connect(skipIdentityCheck: true) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }
}
