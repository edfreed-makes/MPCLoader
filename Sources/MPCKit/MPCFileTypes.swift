import Foundation

/// The kinds of file an MPC can use. Anything else is left on the Mac when copying to the MPC.
///
/// Sources: Akai's support pages list the sample formats (AIF/AIFF, FLAC, MP3, OGG, WAV) and the
/// older Akai formats the MPC still loads (.AKP, .ALL, .IPT, .PGM, .PRJ, .SND, .MID, .SEQ, .APS,
/// .50k, .50s). The rest are the MPC's own project, program, sequence and expansion files.
/// To change what gets copied, edit the tables below.
public enum MPCFileTypes {
    /// Audio the MPC loads as samples.
    public static let audio: [String: String] = [
        "wav": "WAV audio",
        "aif": "AIFF audio",
        "aiff": "AIFF audio",
        "mp3": "MP3 audio",
        "flac": "FLAC audio",
        "ogg": "Ogg audio",
    ]

    /// Files the MPC creates and reads itself.
    public static let native: [String: String] = [
        "xpj": "MPC project",
        "xpm": "MPC program",
        "sxq": "MPC sequence",
        "xal": "MPC project archive",
        "xpn": "MPC expansion",
        "xid": "MPC pad file",
        "mpcpattern": "MPC pattern",
        "progression": "MPC chord progression",
        "mid": "MIDI file",
    ]

    /// Formats from earlier Akai samplers that the MPC still loads.
    public static let legacy: [String: String] = [
        "snd": "MPC sample",
        "pgm": "MPC legacy program",
        "akp": "Akai S-series program",
        "all": "MPC legacy sequences",
        "seq": "MPC legacy sequence",
        "aps": "MPC legacy program set",
        "prj": "MPC legacy project",
        "ipt": "MPC legacy file",
        "50k": "MPC 500 kit",
        "50s": "MPC 500 sequence",
    ]

    static let all: [String: String] = audio.merging(native) { first, _ in first }.merging(legacy) { first, _ in first }

    /// The part of a file name after the last dot, lower-cased. Empty when there is none.
    public static func fileExtension(of name: String) -> String {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
        return name[name.index(after: dot)...].lowercased()
    }

    /// True when the MPC can use a file with this name.
    public static func isCompatible(fileName: String) -> Bool {
        all[fileExtension(of: fileName)] != nil
    }

    /// A short description of a compatible type, for the Kind column. nil for other types.
    public static func description(forExtension ext: String) -> String? {
        all[ext.lowercased()]
    }

    /// A one-line summary for messages.
    public static let summary = "audio (WAV, AIFF, MP3, FLAC, OGG) and MPC files (projects, programs, sequences, expansions, MIDI)"

    // MARK: Folders with their own rules

    /// An expansion keeps a description file and cover artwork next to its sounds.
    public static let expansionManifest = "expansion.xml"
    static let expansionArtwork: Set<String> = ["jpg", "jpeg", "png"]

    /// A plugin for the MPC is a folder holding a `plugin.json` plus its program and screen files.
    /// Everything inside such a folder belongs to the plugin.
    public static let pluginManifest = "plugin.json"

    public static func isExpansionFile(fileName: String) -> Bool {
        let lower = fileName.lowercased()
        return lower == expansionManifest || expansionArtwork.contains(fileExtension(of: lower))
    }
}
