import Tint

struct HelpOverlayRenderer {
    private static let bindings: [(key: String, desc: String)] = [
        ("j/k", "Move up/down"),
        ("h/l", "Focus sidebar/tracks"),
        ("Tab", "Toggle focus"),
        ("Enter", "Select album/play track"),
        ("Space", "Play/pause"),
        ("n/p", "Next/previous track"),
        ("/", "Search albums"),
        ("c", "Clear filter"),
        ("v", "Cycle visualizer"),
        ("\u{2190}/\u{2192}", "Scroll left/right"),
        ("0", "Reset scroll"),
        ("?", "Toggle this help"),
        ("q", "Quit"),
    ]

    static func render(
        area: Rect,
        theme: PlayerTheme,
        buffer: inout Buffer
    ) {
        let overlayWidth = 36
        let overlayHeight = bindings.count + 4  // title + blank + bindings + blank
        let x = max(area.x, area.x + (area.width - overlayWidth) / 2)
        let y = max(area.y, area.y + (area.height - overlayHeight) / 2)
        let overlay = Rect(
            x: x, y: y,
            width: min(overlayWidth, area.width),
            height: min(overlayHeight, area.height)
        )

        let bgStyle = Style(bg: .rgb(30, 15, 50))

        // Fill background behind the entire overlay including border
        buffer.fill(overlay, cell: Cell(character: " ", style: bgStyle))

        let block = Block(
            title: "Shortcuts",
            titleStyle: theme.title.merging(bgStyle),
            borderStyle: .rounded,
            style: theme.border.merging(bgStyle)
        )
        block.render(area: overlay, buffer: &buffer)

        let inner = overlay.inner
        guard !inner.isEmpty else { return }

        let keyStyle = theme.accent.merging(bgStyle)
        let descStyle = theme.primary.merging(bgStyle)

        for (i, binding) in bindings.enumerated() {
            let row = inner.y + i
            guard row < inner.bottom else { break }
            let padded = binding.key.padding(toLength: 8, withPad: " ", startingAt: 0)
            buffer.write(padded, x: inner.x + 1, y: row, style: keyStyle)
            buffer.write(binding.desc, x: inner.x + 10, y: row, style: descStyle)
        }
    }
}
