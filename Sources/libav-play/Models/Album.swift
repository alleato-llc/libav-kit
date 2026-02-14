import Foundation

struct Album: Sendable {
    let name: String
    let artist: String
    let tracks: [Track]

    var displayName: String {
        "\(artist) - \(name)"
    }

    var trackCount: Int { tracks.count }

    var totalDuration: TimeInterval {
        tracks.reduce(0) { $0 + $1.duration }
    }

    var formattedDuration: String {
        let total = Int(totalDuration)
        let mins = total / 60
        let secs = total % 60
        return String(format: "%d:%02d", mins, secs)
    }
}
