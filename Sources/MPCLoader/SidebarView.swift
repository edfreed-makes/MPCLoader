import SwiftUI
import MPCKit

/// The list of drives on the MPC, grouped the way the MPC's own browser thinks of them.
struct SidebarView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        List(selection: driveSelection) {
            if model.isConnected {
                section("Internal", kind: .internalStorage)
                section("Drives", kind: .removable)
                section("Factory Content", kind: .factoryContent)
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if !model.isConnected {
                placeholder("Not Connected", "Your MPC's drives appear here once you connect.")
            } else if model.drives.isEmpty {
                placeholder("No Drives", "The MPC has no storage mounted. Insert an SD card or USB drive.")
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if model.isConnected {
                deviceFooter
            }
        }
    }

    private var driveSelection: Binding<String?> {
        Binding(get: { model.currentDrive?.id }, set: { model.showDrive(id: $0) })
    }

    @ViewBuilder
    private func section(_ title: String, kind: Drive.Kind) -> some View {
        let drives = model.drives.filter { $0.kind == kind }
        if !drives.isEmpty {
            Section(title) {
                ForEach(drives) { drive in
                    DriveRow(drive: drive)
                        // Dropping items on a drive moves them to its top level.
                        .moveDropTarget(drive.mountPoint)
                        .tag(drive.id)
                }
            }
        }
    }

    private func placeholder(_ title: String, _ detail: String) -> some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(16)
    }

    private var deviceFooter: some View {
        VStack(alignment: .leading, spacing: 2) {
            Divider()
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 7))
                        .foregroundStyle(.green)
                    Text(model.deviceName)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                }
                Text(footerDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            .padding(.top, 8)
            .padding(.horizontal, 12)
            // The explicit way out, always on show beside the connection it ends.
            Button { model.disconnect() } label: {
                Label("Disconnect", systemImage: "eject.fill")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.small)
            .help("Disconnect from the MPC (⌘K)")
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .padding(.bottom, 10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footerDetail: String {
        var parts: [String] = []
        if let firmware = model.deviceInfo?.firmware, !firmware.isEmpty { parts.append("MPC OS \(firmware)") }
        parts.append(model.host.trimmingCharacters(in: .whitespaces))
        return parts.joined(separator: " · ")
    }
}

private struct DriveRow: View {
    let drive: Drive

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(drive.displayName)
                        .lineLimit(1)
                    if !drive.isWritable {
                        Image(systemName: "lock.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .help("Read-only: files can be copied from here but not changed")
                    }
                }
                if let space = drive.spaceDescription {
                    Text(space)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        } icon: {
            Image(systemName: drive.symbolName)
        }
        .padding(.vertical, 2)
    }
}
