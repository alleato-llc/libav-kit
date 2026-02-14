import Tint
import LibAVKit

struct TrackListRenderer {
    static func render(
        state: PlayerState,
        area: Rect,
        theme: PlayerTheme,
        buffer: inout Buffer
    ) {
        guard let album = state.selectedAlbum else { return }

        let isFocused = state.focus == .trackList
        let borderStyle: Style = isFocused ? theme.accent : theme.border

        let block = Block(
            title: "\(album.artist) - \(album.name)",
            titleStyle: isFocused ? theme.accent : theme.title,
            borderStyle: .rounded,
            style: borderStyle
        )
        block.render(area: area, buffer: &buffer)

        let innerArea = area.inner
        guard !innerArea.isEmpty, innerArea.height > 1 else { return }

        // Album info line
        let infoText = "  \(album.trackCount) tracks - \(album.formattedDuration)"
        buffer.write(infoText, x: innerArea.x, y: innerArea.y, style: theme.secondary)

        // Track table below info line
        let tableArea = Rect(
            x: innerArea.x,
            y: innerArea.y + 1,
            width: innerArea.width,
            height: max(0, innerArea.height - 1)
        )
        guard !tableArea.isEmpty else { return }

        let rows = album.tracks.enumerated().map { index, track -> Table.Row in
            let isPlaying = state.currentTrack?.url == track.url
            let playingIndicator = isPlaying ? " ▶" : ""
            let style: Style = isPlaying ? theme.accent : theme.primary
            return Table.Row(
                ["\(track.trackNumber)", "\(track.title)\(playingIndicator)", track.formattedDuration],
                style: style
            )
        }

        let table = Table(
            columns: [
                .init("#", width: .fixed(3)),
                .init("Title", width: .fill),
                .init("Duration", width: .fixed(8)),
            ],
            rows: rows,
            selected: isFocused ? state.selectedTrackIndex : nil,
            headerStyle: theme.title,
            highlightStyle: theme.highlight,
            columnSpacing: 1,
            horizontalOffset: state.trackListHScroll
        )
        table.render(area: tableArea, buffer: &buffer)
    }
}
