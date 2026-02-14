import Tint

struct SidebarRenderer {
    static func render(
        state: PlayerState,
        area: Rect,
        theme: PlayerTheme,
        buffer: inout Buffer
    ) {
        let isFocused = state.focus == .sidebar
        let borderStyle: Style = isFocused ? theme.accent : theme.border

        let block = Block(
            title: "Library",
            titleStyle: isFocused ? theme.accent : theme.title,
            borderStyle: .rounded,
            style: borderStyle
        )
        block.render(area: area, buffer: &buffer)

        let innerArea = area.inner
        guard !innerArea.isEmpty else { return }

        let filteredIndices = state.filteredAlbumIndices
        let items = filteredIndices.map { index -> ListWidget.Item in
            let album = state.albums[index]
            let isPlaying = state.currentTrack.map { track in
                album.tracks.contains { $0.url == track.url }
            } ?? false
            let prefix = isPlaying ? "♪ " : ""
            let style = isPlaying ? theme.accent : theme.primary
            return ListWidget.Item("\(prefix)\(album.displayName)", style: style)
        }

        let selectedPos = filteredIndices.firstIndex(of: state.selectedAlbumIndex)
        let list = ListWidget(
            items: items,
            selected: isFocused ? selectedPos : nil,
            highlightStyle: theme.highlight,
            highlightSymbol: "> ",
            horizontalOffset: state.sidebarHScroll
        )
        list.render(area: innerArea, buffer: &buffer)
    }
}
