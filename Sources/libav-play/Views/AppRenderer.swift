import Tint

struct AppRenderer {
    static func render(
        state: PlayerState,
        area: Rect,
        theme: PlayerTheme,
        buffer: inout Buffer
    ) {
        // Layout: main content area + bottom panel
        let sections = Layout(direction: .vertical, constraints: [
            .fill, .fixed(5),
        ]).split(area)

        let mainArea = sections[0]
        let bottomArea = sections[1]

        // Main: sidebar (30%) + track list (70%)
        let columns = Layout(direction: .horizontal, constraints: [
            .percentage(20), .fill,
        ]).split(mainArea)

        SidebarRenderer.render(state: state, area: columns[0], theme: theme, buffer: &buffer)
        TrackListRenderer.render(state: state, area: columns[1], theme: theme, buffer: &buffer)

        // Bottom: oscilloscope (40%) + now-playing (60%)
        let bottomColumns = Layout(direction: .horizontal, constraints: [
            .percentage(40), .fill,
        ]).split(bottomArea)

        switch state.visualizerMode {
        case .oscilloscope:
            OscilloscopeRenderer.render(
                sampleBuffer: state.sampleBuffer,
                area: bottomColumns[0],
                theme: theme,
                buffer: &buffer
            )
        case .spectrum:
            SpectrumRenderer.render(
                sampleBuffer: state.sampleBuffer,
                area: bottomColumns[0],
                theme: theme,
                buffer: &buffer
            )
        }
        NowPlayingRenderer.render(state: state, area: bottomColumns[1], theme: theme, buffer: &buffer)

        // Search overlay
        if state.isSearching {
            renderSearchBar(state: state, area: bottomArea, theme: theme, buffer: &buffer)
        }

        // Help overlay
        if state.isShowingHelp {
            HelpOverlayRenderer.render(area: area, theme: theme, buffer: &buffer)
        }
    }

    private static func renderSearchBar(
        state: PlayerState,
        area: Rect,
        theme: PlayerTheme,
        buffer: inout Buffer
    ) {
        buffer.fill(area, cell: Cell(character: " ", style: theme.statusBar))
        let searchText = " / \(state.searchQuery)█"
        buffer.write(searchText, x: area.x, y: area.y, style: theme.statusBar.merging(Style(bold: true)))
    }
}
