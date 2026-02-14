import Tint

struct OscilloscopeRenderer {
    // Braille left-column dot bits for sub-positions 0–3 (top to bottom within a cell)
    private static let brailleDotBits: [UInt32] = [0x01, 0x02, 0x04, 0x40]
    private static let brailleBase: UInt32 = 0x2800

    static func render(
        sampleBuffer: SampleBuffer,
        area: Rect,
        theme: PlayerTheme,
        buffer: inout Buffer
    ) {
        guard !area.isEmpty else { return }

        let block = Block(
            title: "Scope",
            titleStyle: theme.title,
            borderStyle: .rounded,
            style: theme.border
        )
        block.render(area: area, buffer: &buffer)

        let inner = area.inner
        guard !inner.isEmpty, inner.height >= 1, inner.width >= 2 else { return }

        // Read all samples and downsample to display width.
        // Taking the signed peak (value with max |magnitude|) per column
        // gives a smooth amplitude envelope instead of raw high-frequency noise.
        let allSamples = sampleBuffer.read(count: sampleBuffer.capacity)
        let blockSize = max(1, allSamples.count / inner.width)
        var peaks = [Float]()
        peaks.reserveCapacity(inner.width)

        for col in 0..<inner.width {
            let start = col * blockSize
            let end = min(start + blockSize, allSamples.count)
            guard start < end else {
                peaks.append(0)
                continue
            }
            var peak: Float = 0
            for i in start..<end {
                if abs(allSamples[i]) > abs(peak) {
                    peak = allSamples[i]
                }
            }
            peaks.append(peak)
        }

        // Auto-normalize: scale peaks so the loudest fills ~80% of half-height.
        // Cap gain at 20x to avoid amplifying near-silence into noise.
        let maxAbs = peaks.max(by: { abs($0) < abs($1) }).map { abs($0) } ?? 0
        let gain: Float = maxAbs > 0.001 ? min(0.8 / maxAbs, 20.0) : 1.0

        let waveStyle = theme.visualizer
        // 4 braille sub-positions per row gives 4× vertical resolution
        let totalLevels = inner.height * 4

        // Draw waveform with braille dots
        var prevLevel: Int? = nil
        for (col, peak) in peaks.enumerated() {
            let x = inner.x + col
            guard x < inner.right else { break }

            let scaled = max(-1.0, min(1.0, peak * gain))
            // Map [-1, 1] to [0, totalLevels-1]: +1 → 0 (top), -1 → totalLevels-1 (bottom)
            let normalized = (1.0 - scaled) / 2.0
            let level = min(totalLevels - 1, Int(normalized * Float(totalLevels - 1)))

            // Collect all levels for this column (main point + gap fill)
            var levels = [level]
            if let pl = prevLevel, abs(pl - level) > 1 {
                let lo = min(pl, level) + 1
                let hi = max(pl, level)
                for fillLevel in lo..<hi {
                    levels.append(fillLevel)
                }
            }

            // Group by row and OR dot bits for multi-dot cells
            var rowBits: [Int: UInt32] = [:]
            for lvl in levels {
                let row = lvl / 4
                let sub = lvl % 4
                rowBits[row, default: 0] |= brailleDotBits[sub]
            }

            // Write braille characters
            for (row, bits) in rowBits {
                let y = inner.y + row
                guard y < inner.bottom else { continue }
                let value = brailleBase | bits
                if let scalar = Unicode.Scalar(value) {
                    buffer[x, y] = Cell(character: Character(scalar), style: waveStyle)
                }
            }

            prevLevel = level
        }
    }
}
