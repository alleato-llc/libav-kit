import Foundation
import LibAVKit

struct LibraryIndex {
    private static let audioExtensions: Set<String> = [
        "flac", "alac", "wav", "aiff", "aif", "wv",
        "mp3", "m4a", "aac", "opus", "ogg",
    ]

    static func scan(directory: URL) -> [Album] {
        let reader = MetadataReader()
        let fm = FileManager.default

        guard let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var tracks: [Track] = []
        for case let fileURL as URL in enumerator {
            let ext = fileURL.pathExtension.lowercased()
            guard audioExtensions.contains(ext) else { continue }

            if let metadata = try? reader.read(url: fileURL) {
                tracks.append(Track(url: fileURL, metadata: metadata))
            }
        }

        // Group by album
        let grouped = Dictionary(grouping: tracks) { "\($0.artist) — \($0.album)" }

        return grouped.values.map { albumTracks in
            let sorted = albumTracks.sorted {
                if $0.discNumber != $1.discNumber { return $0.discNumber < $1.discNumber }
                return $0.trackNumber < $1.trackNumber
            }
            return Album(
                name: sorted.first?.album ?? "Unknown Album",
                artist: sorted.first?.artist ?? "Unknown Artist",
                tracks: sorted
            )
        }.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }
}
