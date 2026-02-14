import Accelerate
import Tint

struct SpectrumRenderer {
    static func render(
        sampleBuffer: SampleBuffer,
        area: Rect,
        theme: PlayerTheme,
        buffer: inout Buffer
    ) {
        guard !area.isEmpty else { return }

        let block = Block(
            title: "Spectrum",
            titleStyle: theme.title,
            borderStyle: .rounded,
            style: theme.border
        )
        block.render(area: area, buffer: &buffer)

        let inner = area.inner
        guard !inner.isEmpty, inner.height >= 2, inner.width >= 2 else { return }

        let bandCount = inner.width
        let magnitudes = computeSpectrum(sampleBuffer: sampleBuffer, bandCount: bandCount)

        // Auto-normalize so loudest band fills full height
        let maxMag = magnitudes.max() ?? 0
        let gain: Float = maxMag > 1e-6 ? 1.0 / maxMag : 0

        let barChars: [Character] = ["▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"]
        let subLevels = barChars.count
        let totalLevels = inner.height * subLevels
        let barStyle = theme.visualizer

        for (col, mag) in magnitudes.enumerated() {
            let x = inner.x + col
            guard x < inner.right else { break }

            let normalized = min(1.0, mag * gain)
            let level = Int(normalized * Float(totalLevels))

            let fullRows = level / subLevels
            let remainder = level % subLevels

            // Draw full block rows from bottom
            for row in 0..<fullRows {
                let y = inner.bottom - 1 - row
                if y >= inner.y {
                    buffer[x, y] = Cell(character: "█", style: barStyle)
                }
            }

            // Draw partial block at the top of the bar
            if remainder > 0 {
                let y = inner.bottom - 1 - fullRows
                if y >= inner.y {
                    buffer[x, y] = Cell(character: barChars[remainder - 1], style: barStyle)
                }
            }
        }
    }

    // MARK: - FFT

    private static func computeSpectrum(sampleBuffer: SampleBuffer, bandCount: Int) -> [Float] {
        let samples = sampleBuffer.read(count: sampleBuffer.capacity)
        let n = samples.count
        guard n >= 4 else { return [Float](repeating: 0, count: bandCount) }

        // Round down to power of 2
        let log2n = vDSP_Length(floor(log2(Float(n))))
        let fftSize = Int(1 << log2n)
        let halfSize = fftSize / 2

        // Apply Hanning window
        var window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))

        var windowed = [Float](repeating: 0, count: fftSize)
        vDSP_vmul(samples, 1, window, 1, &windowed, 1, vDSP_Length(fftSize))

        // Set up FFT
        guard let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            return [Float](repeating: 0, count: bandCount)
        }
        defer { vDSP_destroy_fftsetup(fftSetup) }

        // Pack into split complex, run FFT, compute magnitudes
        var realp = [Float](repeating: 0, count: halfSize)
        var imagp = [Float](repeating: 0, count: halfSize)
        var magnitudes = [Float](repeating: 0, count: halfSize)

        realp.withUnsafeMutableBufferPointer { realBuf in
            imagp.withUnsafeMutableBufferPointer { imagBuf in
                var split = DSPSplitComplex(
                    realp: realBuf.baseAddress!,
                    imagp: imagBuf.baseAddress!
                )

                windowed.withUnsafeBufferPointer { ptr in
                    ptr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfSize) { complexPtr in
                        vDSP_ctoz(complexPtr, 2, &split, 1, vDSP_Length(halfSize))
                    }
                }

                vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
                vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(halfSize))
            }
        }

        // Group into bands using logarithmic frequency distribution
        return logBands(magnitudes: magnitudes, bandCount: bandCount)
    }

    private static func logBands(magnitudes: [Float], bandCount: Int) -> [Float] {
        let binCount = magnitudes.count
        guard binCount > 0, bandCount > 0 else {
            return [Float](repeating: 0, count: bandCount)
        }

        var bands = [Float](repeating: 0, count: bandCount)

        // Map bands to FFT bins on a logarithmic scale
        // Band i covers bins from logStart(i) to logStart(i+1)
        for i in 0..<bandCount {
            let loFrac = Float(i) / Float(bandCount)
            let hiFrac = Float(i + 1) / Float(bandCount)

            // Exponential mapping: bin = binCount^(frac) scaled to [0, binCount)
            let loBin = Int(pow(Float(binCount), loFrac) - 1)
            let hiBin = Int(pow(Float(binCount), hiFrac) - 1)

            let lo = max(0, min(loBin, binCount - 1))
            let hi = max(lo, min(hiBin, binCount - 1))

            // Average magnitude in this bin range
            var sum: Float = 0
            for b in lo...hi {
                sum += magnitudes[b]
            }
            bands[i] = sum / Float(hi - lo + 1)
        }

        return bands
    }
}
