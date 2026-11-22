import Foundation

/// One page of the built-in help.
struct HelpTopic: Identifiable, Hashable {
    let id: String
    let title: String
    let symbol: String
    /// One sentence under the title, saying what the page covers.
    let summary: String
    let blocks: [HelpBlock]

    /// Everything on the page as plain text, for searching.
    var searchText: String {
        ([title, summary] + blocks.flatMap(\.texts)).joined(separator: " ").lowercased()
    }
}

/// The building blocks of a help page. Text may use **bold** and [links](https://example.com).
enum HelpBlock: Hashable {
    case heading(String)
    case text(String)
    case steps([String])
    case bullets([String])
    case shortcuts([HelpShortcut])
    case note(String)

    var texts: [String] {
        switch self {
        case .heading(let s), .text(let s), .note(let s): return [s]
        case .steps(let list), .bullets(let list): return list
        case .shortcuts(let list): return list.flatMap { [$0.keys, $0.action] }
        }
    }
}

struct HelpShortcut: Hashable {
    let keys: String
    let action: String

    init(_ keys: String, _ action: String) {
        self.keys = keys
        self.action = action
    }
}

/// The help itself. Written to match what the app does; update it alongside the app.
enum HelpContent {
    static let firstTopic = "getting-started"

    static func topic(_ id: String?) -> HelpTopic? {
        topics.first { $0.id == id }
    }

    static let topics: [HelpTopic] = [
        HelpTopic(
            id: "getting-started",
            title: "Getting Started",
            symbol: "sparkles",
            summary: "MPC Loader copies samples between your Mac and your Akai MPC over your home network, with no cables and no card swapping.",
            blocks: [
                .heading("What you need"),
                .bullets([
                    "A Mac running macOS 14 (Sonoma) or later.",
                    "An MPC running MPC OS 3.10.1 or later, with **developer mode** switched on. See [Developer Mode](help:developer-mode).",
                    "The Mac and the MPC on the same Wi-Fi or wired network.",
                ]),
                .heading("Your first connection"),
                .steps([
                    "Switch on developer mode on the MPC.",
                    "Open MPC Loader and click **Find MPC**. It searches your network and fills in the MPC's address.",
                    "Click **Connect**.",
                    "If macOS asks whether MPC Loader may find devices on your local network, click **Allow**.",
                    "Your MPC's drives appear in the sidebar. Pick one and start copying.",
                ]),
                .heading("Moving samples"),
                .bullets([
                    "**To the MPC:** drag files or folders from Finder into the window.",
                    "**To your Mac:** drag items out of the window into Finder.",
                    "**Between folders on the MPC:** drag items onto a folder in the window.",
                    "**To listen first:** select a sample and press the space bar.",
                ]),
                .note("MPC Loader has been tested on an MPC Live II running MPC OS 3.10.1. On other models, start with files you have a copy of. MPC Loader is not made or endorsed by Akai Professional or inMusic."),
            ]),

        HelpTopic(
            id: "developer-mode",
            title: "Developer Mode",
            symbol: "wrench.and.screwdriver",
            summary: "Developer mode starts the MPC's built-in file connection (its SSH server), which MPC Loader uses to reach the MPC's drives.",
            blocks: [
                .heading("On MPC OS 3.10.1"),
                .steps([
                    "On the MPC, open **Preferences**, then **Info**.",
                    "Tap the version value 3 times.",
                    "Tap the serial number value 2 times.",
                    "Tap the firmware version once.",
                    "Developer mode is now on. Connect from MPC Loader.",
                ]),
                .text("Menu names can change between MPC OS versions. If these steps don't match your MPC, check Akai's guide in the MPC Plugin SDK on GitHub."),
                .heading("Keep it safe"),
                .text("While developer mode is on, any device on your network can log in to the MPC without a password. That is fine on your home network. Switch it off again before you take the MPC onto a network you don't control, such as a venue or studio Wi-Fi."),
            ]),

        HelpTopic(
            id: "connecting",
            title: "Connecting to Your MPC",
            symbol: "cable.connector",
            summary: "How MPC Loader finds your MPC, the login it uses, and how to disconnect.",
            blocks: [
                .heading("Finding the MPC"),
                .text("**Find MPC** checks the other devices on your Mac's network for one that answers like an MPC in developer mode, then fills in its address. It runs by itself the first time you open the app."),
                .text("If it finds nothing, type the address yourself. On the MPC it is under **Preferences**, then **Wi-Fi** (hold Shift to reach the tab) or **Ethernet**. It looks like 192.168.1.50."),
                .heading("Login details"),
                .text("MPC Loader uses the MPC's standard login: user name **root**, no password, port 22. If you have changed these on your MPC, open **Login Details** on the connect screen and enter your own. A password you enter is kept in your Mac's Keychain."),
                .text("**Use MPC Defaults** puts the standard login back."),
                .heading("Local network permission"),
                .text("The first time MPC Loader looks for your MPC, macOS asks whether it may find devices on your local network. Click **Allow**. If you clicked Don't Allow, change it in **System Settings**, **Privacy & Security**, **Local Network**."),
                .heading("Disconnecting"),
                .text("Click **Disconnect** under the MPC's name at the bottom of the sidebar, or choose **MPC**, **Disconnect** (⌘K). Quitting the app also disconnects."),
            ]),

        HelpTopic(
            id: "browsing",
            title: "Finding Your Way Around",
            symbol: "sidebar.left",
            summary: "The sidebar, the four views, sorting, and the path bar.",
            blocks: [
                .heading("Drives"),
                .text("The sidebar lists the MPC's storage:"),
                .bullets([
                    "**Internal:** the MPC's built-in storage.",
                    "**Drives:** SD cards, USB drives and any fitted SATA drive.",
                    "**Factory Content:** the MPC's built-in sounds. You can copy from them but not change them, so a lock appears beside the name.",
                ]),
                .text("Plug a card or drive into the MPC and it appears within a few seconds. Remove one and it disappears."),
                .heading("Opening folders"),
                .text("Double-click a folder to open it. The **path bar** along the bottom shows where you are: click any part of it to jump back. **Back** and **Forward** work as they do in Finder."),
                .heading("Views"),
                .text("The four buttons in the toolbar show items as **Icons**, a **List**, **Columns** or a **Gallery**, just like Finder. Your choice is remembered."),
                .heading("Sorting"),
                .text("The **Sort** button in the toolbar, or **View**, **Sort By**, orders items by Name, Kind, Date Modified or Size, ascending or descending. In List view you can also click a column heading."),
                .heading("Filtering and hidden files"),
                .text("Type in the search field at the top right to show only items whose names match. **View**, **Show Hidden Files** shows files whose names start with a full stop."),
            ]),

        HelpTopic(
            id: "copy-to-mpc",
            title: "Copying to the MPC",
            symbol: "arrow.up.doc",
            summary: "Send samples, kits and projects from your Mac to the folder that is open in MPC Loader.",
            blocks: [
                .heading("Two ways to copy"),
                .bullets([
                    "Drag files or folders from Finder into the MPC Loader window.",
                    "Or click **Copy to MPC** in the toolbar (⌘U) and choose them.",
                ]),
                .text("A progress bar along the bottom shows how the copy is going. Click **Cancel** to stop it."),
                .heading("Which files are copied"),
                .text("Only files the MPC can use:"),
                .bullets([
                    "**Audio:** WAV, AIFF, MP3, FLAC and OGG.",
                    "**MPC files:** projects, programs, sequences, expansions and MIDI files.",
                    "**Older Akai formats** the MPC still loads, such as SND and PGM.",
                    "**Expansion folders** keep their description file and cover artwork, and **plugin folders** are copied whole.",
                ]),
                .text("Anything else stays on your Mac. When the copy finishes, a report lists what was left out and why."),
                .heading("Names the drive won't accept"),
                .text("Cards and drives formatted on the MPC use the exFAT format, which doesn't allow these characters in names: \" * : < > ? \\ |. Nor can a name end with a space or a full stop. Such files are left out and listed in the report: rename them on your Mac and copy them again. The MPC's internal storage has no such limits. A drive formatted as FAT32 also can't hold a file over 4 GB."),
                .heading("When something is already there"),
                .text("MPC Loader checks the destination before copying. If an item of the same name is already there, it asks what to do:"),
                .bullets([
                    "**Replace** overwrites what is on the MPC, and tells you how many files that is. For a folder, only files with the same names are overwritten; everything else in it is kept. When nothing would be overwritten, the button reads **Merge**.",
                    "**Keep Both** copies yours in alongside under a new name, such as \"Kick 2.wav\".",
                    "**Skip** leaves what is on the MPC alone and copies the rest. Pressing Return chooses Skip.",
                    "**Cancel** copies nothing.",
                ]),
                .text("Files that are already on the MPC and identical are never sent again, so copying a folder you have mostly sent before only sends what is new or changed."),
                .note("Each file arrives whole or not at all. If a copy is cancelled or the connection drops, no half-written sample is left behind."),
            ]),

        HelpTopic(
            id: "copy-to-mac",
            title: "Copying to Your Mac",
            symbol: "arrow.down.doc",
            summary: "Bring samples, kits and projects from the MPC onto your Mac.",
            blocks: [
                .heading("Two ways to copy"),
                .bullets([
                    "Drag items out of the MPC Loader window into Finder, or into another app that takes files. The copy starts when you drop them.",
                    "Or select items, click **Copy to Mac** in the toolbar (⌘D), and choose a folder.",
                ]),
                .text("When the copy finishes, click **Show in Finder** in the bar along the bottom to see the files."),
                .heading("Nothing on your Mac is replaced"),
                .text("If the folder you copy into already holds something with the same name, the new copy gets a number added, such as \"Kick 2.wav\"."),
            ]),

        HelpTopic(
            id: "preview",
            title: "Listening to Samples",
            symbol: "play.circle",
            summary: "Hear a sample before you copy it.",
            blocks: [
                .heading("Play a sample"),
                .bullets([
                    "Select an audio file and press the **space bar**.",
                    "Or double-click it.",
                    "Or click the **play** button in the toolbar, or choose **File**, **Preview** (⌘Y).",
                ]),
                .text("A small player appears at the bottom of the window. Press the space bar again to stop."),
                .heading("Step through a folder"),
                .text("While the player is open, the arrow keys move to the next or previous file and play it, so you can audition a whole kit quickly."),
                .heading("Formats"),
                .text("Previews play WAV, AIFF, MP3 and FLAC. macOS has no built-in support for Ogg audio, so an Ogg file can be copied but not previewed."),
                .note("To play a sample, MPC Loader copies it to your Mac's temporary folder. Nothing is created on the MPC, and the temporary copies are removed when you quit."),
            ]),

        HelpTopic(
            id: "organising",
            title: "Organising Files",
            symbol: "folder.badge.gearshape",
            summary: "Create folders, and move, rename and delete items on the MPC.",
            blocks: [
                .bullets([
                    "**New folder:** click the new folder button in the toolbar, or choose **File**, **New Folder** (⇧⌘N).",
                    "**Rename:** select one item and choose **File**, **Rename**, or right-click it.",
                    "**Delete:** select items and press ⌘Delete, or choose **File**, **Delete**. Deleting from the MPC can't be undone.",
                ]),
                .heading("Moving items between folders"),
                .text("Drag files or folders onto a folder to move them into it. This works in every view. You can also drop them on a folder in the path bar at the bottom of the window, which is handy for moving something up a level, or on a drive in the sidebar to move them to the drive's top level."),
                .bullets([
                    "**Several at once:** select them first, then drag any one of them.",
                    "**Changed your mind?** Choose **Edit**, **Undo Move** (⌘Z) and they go back where they were. **Edit**, **Redo Move** (⇧⌘Z) moves them again.",
                    "**A name that's already there:** if the folder already holds something with the same name, you're asked what to do. **Skip** leaves that item where it is and moves the rest. It's the default, so pressing Return never renames anything. **Keep Both** moves it in with a number added to its name, for example “Kick 2.wav”. **Cancel** moves nothing.",
                    "**Copying instead of moving:** dragging items out of the window, into Finder or onto the Desktop, copies them to your Mac and leaves them on the MPC.",
                ]),
                .note("Items move within one drive. Moving is only a change of address on the drive, so it's instant whatever the size, and nothing is copied. To put something on another drive, copy it to your Mac, then copy it from your Mac to that drive."),
                .heading("What MPC Loader won't change"),
                .text("MPC Loader only reaches the MPC's storage drives. It can't see or change the MPC's own system files, so nothing you do in it can stop the MPC working. Factory content can be copied but not changed, and the top folder of a drive can't be renamed or deleted."),
            ]),

        HelpTopic(
            id: "shortcuts",
            title: "Keyboard Shortcuts",
            symbol: "keyboard",
            summary: "Everything in MPC Loader can be done from the keyboard.",
            blocks: [
                .heading("Connection"),
                .shortcuts([
                    HelpShortcut("⌘K", "Connect or disconnect"),
                ]),
                .heading("Moving around"),
                .shortcuts([
                    HelpShortcut("⌘1  ⌘2  ⌘3  ⌘4", "Show as Icons, List, Columns or Gallery"),
                    HelpShortcut("Arrow keys", "Select the next item"),
                    HelpShortcut("⌘[", "Back"),
                    HelpShortcut("⌘]", "Forward"),
                    HelpShortcut("⌘↑", "Enclosing folder"),
                    HelpShortcut("⌘R", "Refresh"),
                    HelpShortcut("⇧⌘.", "Show or hide hidden files"),
                ]),
                .heading("Files"),
                .shortcuts([
                    HelpShortcut("Space or ⌘Y", "Play or stop a preview"),
                    HelpShortcut("⌘U", "Copy files to the MPC"),
                    HelpShortcut("⌘D", "Copy the selection to your Mac"),
                    HelpShortcut("⇧⌘N", "New folder"),
                    HelpShortcut("⌘Delete", "Delete"),
                    HelpShortcut("⌘Z", "Undo a move"),
                    HelpShortcut("⇧⌘Z", "Redo a move"),
                ]),
                .heading("Help"),
                .shortcuts([
                    HelpShortcut("⌘?", "Open this help"),
                ]),
            ]),

        HelpTopic(
            id: "troubleshooting",
            title: "Troubleshooting",
            symbol: "questionmark.circle",
            summary: "What the messages mean, and what to do about them.",
            blocks: [
                .heading("Find MPC finds nothing"),
                .text("Check the MPC is switched on, in developer mode and on the same network as your Mac. Check MPC Loader is allowed to find devices on your local network, in **System Settings**, **Privacy & Security**, **Local Network**. Or type the MPC's address yourself."),
                .heading("\"The MPC is there, but developer mode looks to be off\""),
                .text("The MPC answered but turned the connection down. Switch on developer mode and connect again. See [Developer Mode](help:developer-mode)."),
                .heading("\"Nothing answered\""),
                .text("Check the address, and that the MPC is on and on the same network. Some guest or office Wi-Fi networks stop devices reaching each other; your home network won't."),
                .heading("\"The MPC wants a password\" or \"was refused\""),
                .text("Someone has set a password on the MPC. Open **Login Details** and enter it. If you never set one, click **Use MPC Defaults**."),
                .heading("\"That doesn't look like an MPC\""),
                .text("Something at that address accepted the login but isn't an MPC. Check the address. If you are sure it is right, click **Connect Anyway**."),
                .heading("\"The connection to the MPC was lost\""),
                .text("The MPC was switched off, left the network, or developer mode was switched off. Connect again once it is back."),
                .heading("A drive is missing from the sidebar"),
                .text("Check it is firmly in the MPC and that the MPC itself can see it. MPC Loader updates the sidebar every few seconds."),
                .heading("\"There isn't enough room\""),
                .text("MPC Loader checks the free space before it starts and copies nothing if the files won't fit. Free some space or choose another drive."),
                .heading("macOS won't open MPC Loader"),
                .text("This version isn't signed with an Apple developer certificate. Open it once, click **Done**, then go to **System Settings**, **Privacy & Security** and click **Open Anyway**."),
            ]),

        HelpTopic(
            id: "privacy",
            title: "Privacy and Safety",
            symbol: "lock.shield",
            summary: "What MPC Loader touches, what it stores and what to watch for.",
            blocks: [
                .bullets([
                    "**Only your drives.** MPC Loader reaches the MPC's storage drives and nothing else. The MPC's system files are out of reach.",
                    "**No account, no internet.** MPC Loader talks only to your MPC, over your own network. It sends nothing anywhere else.",
                    "**Your password stays in your Keychain.** It is sent only to the MPC you connect to, and Find MPC never sends it to other devices.",
                    "**Temporary files stay on your Mac.** Previews and dragged-out items are copied to your Mac's temporary folder and removed when you quit.",
                ]),
                .heading("Things to know"),
                .bullets([
                    "Developer mode lets any device on your network log in to the MPC. Switch it off on networks you don't control.",
                    "Like Akai's own tools, MPC Loader doesn't check the MPC's identity when it connects, because that changes whenever the MPC is updated. On your home network this is a sensible trade. Avoid typing a custom password on a network you don't trust.",
                ]),
            ]),
    ]
}
