import SwiftUI
import AppKit
import MPCKit

/// Shown once a copy has finished whenever something was left out, failed or was stopped.
struct ReportSheet: View {
    @Environment(\.dismiss) private var dismiss
    let report: AppModel.TransferReport

    private var groups: [(reason: SkippedItem.Reason, items: [SkippedItem])] {
        let order: [SkippedItem.Reason] = [.unsupportedType, .nameNotAllowed, .tooLarge, .link, .unreadable, .alreadyThere]
        return order.compactMap { reason in
            let items = report.skipped.filter { $0.reason == reason }
            return items.isEmpty ? nil : (reason: reason, items: items)
        }
    }

    private var leftOutCount: Int { report.skipped.count + report.failures.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: report.copiedFiles > 0 && report.stoppedBecause == nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(report.copiedFiles > 0 && report.stoppedBecause == nil ? Color.green : Color.yellow)
                VStack(alignment: .leading, spacing: 4) {
                    Text(headline)
                        .font(.headline)
                    Text(subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let reason = report.stoppedBecause {
                Text(reason)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            if leftOutCount > 0 {
                List {
                    ForEach(groups, id: \.reason) { group in
                        Section(group.reason.heading(driveFormat: report.driveFormat)) {
                            ForEach(group.items, id: \.self) { item in
                                Label(item.name, systemImage: item.isFolder ? "folder" : "doc")
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .help(item.name)
                            }
                        }
                    }
                    if !report.failures.isEmpty {
                        Section("Went wrong during the copy") {
                            ForEach(report.failures) { failure in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(failure.name)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Text(failure.message)
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
                .frame(minHeight: 160, idealHeight: 260)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
            }

            if report.toMPC {
                ForEach(groups.compactMap { $0.reason.advice }, id: \.self) { advice in
                    Text(advice)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack {
                if leftOutCount > 0 {
                    Button("Copy List") { copyList() }
                        .help("Put this list on the clipboard")
                }
                Spacer()
                Button("OK") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 540)
    }

    private var destination: String {
        report.toMPC ? "“\(report.destination)” on the MPC" : "“\(report.destination)” on this Mac"
    }

    private var headline: String {
        if report.stoppedBecause != nil { return report.copiedFiles > 0 ? "The copy stopped early" : "Nothing was copied" }
        if report.cancelled { return "The copy was cancelled" }
        if report.copiedFiles == 0 { return "Nothing was copied" }
        return "Copy finished, with some items left out"
    }

    private var subheadline: String {
        var parts: [String] = []
        if report.copiedFiles > 0 {
            parts.append("\(Format.count(report.copiedFiles, "file was", "files were")) copied to \(destination).")
        }
        if leftOutCount > 0 {
            parts.append("\(Format.count(leftOutCount, "item was", "items were")) not copied:")
        } else if report.cancelled && report.plannedFiles > report.copiedFiles {
            parts.append("\(Format.count(report.plannedFiles - report.copiedFiles, "file was", "files were")) not copied.")
        }
        return parts.joined(separator: " ")
    }

    private func copyList() {
        var lines: [String] = [headline, subheadline, ""]
        if let reason = report.stoppedBecause { lines += [reason, ""] }
        for group in groups {
            lines.append(group.reason.heading(driveFormat: report.driveFormat) + ":")
            lines += group.items.map { "  " + $0.name }
            lines.append("")
        }
        if !report.failures.isEmpty {
            lines.append("Went wrong during the copy:")
            lines += report.failures.map { "  \($0.name): \($0.message)" }
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }
}

/// Asked before copying to the MPC when something of the same name is already there.
struct ConflictSheet: View {
    let question: AppModel.ConflictQuestion
    let answer: (AppModel.ConflictAnswer) -> Void

    private var replaceLabel: String {
        question.overwriteCount == 0 && question.mergesFolders ? "Merge" : "Replace"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.yellow)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                    if question.names.count > 1 {
                        Text(nameList)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 8) {
                choice(replaceLabel, replaceText)
                if !question.keepBothExample.isEmpty {
                    choice("Keep Both", "Copies yours in alongside under a new name, such as “\(question.keepBothExample)”. Nothing on the MPC is touched.")
                }
                choice("Skip", "Leaves what is on the MPC as it is and copies the rest.")
                choice("Cancel", "Copies nothing.")
            }

            HStack {
                Button("Cancel", role: .cancel) { answer(.cancel) }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(replaceLabel) { answer(.replace) }
                Button("Keep Both") { answer(.keepBoth) }
                // Skip is the default, so pressing Return never overwrites or duplicates anything.
                Button("Skip") { answer(.skip) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 540)
    }

    private func choice(_ name: String, _ explanation: String) -> some View {
        GridRow {
            Text(name)
                .fontWeight(.semibold)
                .gridColumnAlignment(.trailing)
            Text(explanation)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var title: String {
        // A queued copy may be going to a folder other than the open one, so it is named.
        let folder = question.folderName.isEmpty ? "this folder" : "“\(question.folderName)”"
        if question.names.count == 1 { return "“\(question.names[0])” already exists in \(folder) on the MPC" }
        return "\(question.names.count) items already exist in \(folder) on the MPC"
    }

    private var nameList: String {
        let shown = question.names.prefix(5).map { "“\($0)”" }.joined(separator: ", ")
        return question.names.count > 5 ? shown + " and \(question.names.count - 5) more" : shown
    }

    private var replaceText: String {
        let files = Format.count(question.overwriteCount, "file", "files")
        // Files that are already across and identical are never sent again.
        let same = question.identicalCount
        let alreadyThere = same == 0 ? "" : " \(Format.count(same, "file is", "files are")) already there and identical, so \(same == 1 ? "it is" : "they are") not sent again."
        if question.overwriteCount > 0, question.mergesFolders {
            return "Overwrites \(files) on the MPC with yours, counting files inside folders that are already there. Everything else in those folders is kept." + alreadyThere
        }
        if question.overwriteCount > 0 {
            return "Overwrites \(files) on the MPC with yours." + alreadyThere
        }
        if question.mergesFolders {
            return "Adds your files to the folder that is already there. Nothing on the MPC is overwritten." + alreadyThere
        }
        return "Can't be done here: one is a folder and the other a file. Choose Keep Both or Skip."
    }
}
