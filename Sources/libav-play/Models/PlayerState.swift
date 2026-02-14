import Foundation
import LibAVKit

enum Focus {
    case sidebar
    case trackList
}

enum VisualizerMode {
    case oscilloscope
    case spectrum
}

final class PlayerState: @unchecked Sendable {
    let albums: [Album]
    private(set) var selectedAlbumIndex: Int = 0
    private(set) var selectedTrackIndex: Int = 0
    private(set) var focus: Focus = .sidebar
    private(set) var searchQuery: String = ""
    private(set) var isSearching: Bool = false
    private(set) var sidebarHScroll: Int = 0
    private(set) var trackListHScroll: Int = 0
    private(set) var visualizerMode: VisualizerMode = .spectrum
    private(set) var isShowingHelp: Bool = false

    let sampleBuffer = SampleBuffer()
    let player: AudioPlayer
    private(set) var currentTrack: Track?

    init(albums: [Album], player: AudioPlayer = AudioPlayer()) {
        self.albums = albums
        self.player = player
        player.onStateChange = { [weak self] state in
            guard let self else { return }
            if state == .completed {
                self.nextTrack()
            }
        }
    }

    var selectedAlbum: Album? {
        guard selectedAlbumIndex < albums.count else { return nil }
        return albums[selectedAlbumIndex]
    }

    var currentAlbumTracks: [Track] {
        selectedAlbum?.tracks ?? []
    }

    var playbackProgress: Double {
        guard player.duration > 0 else { return 0 }
        return player.currentTime / player.duration
    }

    // MARK: - Navigation

    func moveUp() {
        switch focus {
        case .sidebar:
            let indices = filteredAlbumIndices
            guard let pos = indices.firstIndex(of: selectedAlbumIndex) else {
                if let first = indices.first {
                    selectedAlbumIndex = first
                    selectedTrackIndex = 0
                }
                return
            }
            if pos > 0 {
                selectedAlbumIndex = indices[pos - 1]
                selectedTrackIndex = 0
            }
        case .trackList:
            if selectedTrackIndex > 0 {
                selectedTrackIndex -= 1
            }
        }
    }

    func moveDown() {
        switch focus {
        case .sidebar:
            let indices = filteredAlbumIndices
            guard let pos = indices.firstIndex(of: selectedAlbumIndex) else {
                if let first = indices.first {
                    selectedAlbumIndex = first
                    selectedTrackIndex = 0
                }
                return
            }
            if pos < indices.count - 1 {
                selectedAlbumIndex = indices[pos + 1]
                selectedTrackIndex = 0
            }
        case .trackList:
            if selectedTrackIndex < currentAlbumTracks.count - 1 {
                selectedTrackIndex += 1
            }
        }
    }

    func focusLeft() {
        focus = .sidebar
    }

    func focusRight() {
        focus = .trackList
    }

    // MARK: - Horizontal Scroll

    private static let hScrollStep = 4

    var activeHScroll: Int {
        switch focus {
        case .sidebar: return sidebarHScroll
        case .trackList: return trackListHScroll
        }
    }

    func scrollRight() {
        switch focus {
        case .sidebar: sidebarHScroll += Self.hScrollStep
        case .trackList: trackListHScroll += Self.hScrollStep
        }
    }

    func scrollLeft() {
        switch focus {
        case .sidebar: sidebarHScroll = max(0, sidebarHScroll - Self.hScrollStep)
        case .trackList: trackListHScroll = max(0, trackListHScroll - Self.hScrollStep)
        }
    }

    func resetHScroll() {
        switch focus {
        case .sidebar: sidebarHScroll = 0
        case .trackList: trackListHScroll = 0
        }
    }

    // MARK: - Visualizer

    func cycleVisualizerMode() {
        switch visualizerMode {
        case .oscilloscope: visualizerMode = .spectrum
        case .spectrum: visualizerMode = .oscilloscope
        }
    }

    // MARK: - Playback

    func playSelected() {
        let tracks = currentAlbumTracks
        guard selectedTrackIndex < tracks.count else { return }
        let track = tracks[selectedTrackIndex]
        playTrack(track)
    }

    func playTrack(_ track: Track) {
        player.stop()
        do {
            try player.open(url: track.url)
            player.play()
            currentTrack = track
        } catch {
            // Silently skip unplayable tracks
        }
    }

    func togglePlayPause() {
        switch player.state {
        case .playing:
            player.pause()
        case .paused:
            player.play()
        case .idle, .stopped, .completed:
            playSelected()
        }
    }

    func nextTrack() {
        let tracks = currentAlbumTracks
        guard !tracks.isEmpty else { return }
        let nextIndex = selectedTrackIndex + 1
        if nextIndex < tracks.count {
            selectedTrackIndex = nextIndex
            playTrack(tracks[nextIndex])
        }
    }

    func previousTrack() {
        let tracks = currentAlbumTracks
        guard !tracks.isEmpty else { return }
        // If more than 3 seconds in, restart current track
        if player.currentTime > 3.0, let track = currentTrack {
            player.seek(to: 0)
            _ = track
            return
        }
        let prevIndex = selectedTrackIndex - 1
        if prevIndex >= 0 {
            selectedTrackIndex = prevIndex
            playTrack(tracks[prevIndex])
        }
    }

    // MARK: - Search

    func startSearch() {
        isSearching = true
        searchQuery = ""
    }

    func commitSearch() {
        isSearching = false
    }

    func cancelSearch() {
        isSearching = false
        searchQuery = ""
    }

    func clearFilter() {
        searchQuery = ""
    }

    // MARK: - Help

    func toggleHelp() {
        isShowingHelp.toggle()
    }

    func appendSearchChar(_ char: Character) {
        searchQuery.append(char)
        snapSelectionToFilter()
    }

    func deleteSearchChar() {
        _ = searchQuery.popLast()
        snapSelectionToFilter()
    }

    private func snapSelectionToFilter() {
        let indices = filteredAlbumIndices
        if !indices.contains(selectedAlbumIndex), let first = indices.first {
            selectedAlbumIndex = first
            selectedTrackIndex = 0
        }
    }

    var filteredAlbumIndices: [Int] {
        guard !searchQuery.isEmpty else {
            return Array(0..<albums.count)
        }
        let query = searchQuery.lowercased()
        return albums.indices.filter {
            albums[$0].displayName.lowercased().contains(query)
        }
    }
}
