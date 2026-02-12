# libav-kit

[![Swift 6.2+](https://img.shields.io/badge/Swift-6.2%2B-orange.svg)](https://swift.org)
[![macOS 14.4+](https://img.shields.io/badge/macOS-14.4%2B-blue.svg)](https://www.apple.com/macos)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![SPM Compatible](https://img.shields.io/badge/SPM-Compatible-brightgreen.svg)](https://swift.org/package-manager)

A Swift package wrapping FFmpeg's C libraries for audio decoding, encoding, playback, metadata reading, tag writing, and cover art embedding. Uses the C API directly — no CLI shelling, no AVFoundation dependency. The only AVFoundation usage is in `AVAudioEngineOutput`, a provided reference implementation of the `AudioOutput` protocol. All other APIs (decoding, encoding, metadata, playback coordination) depend only on Foundation and CFFmpeg.

## Requirements

- macOS 14.4+
- Swift 6.2+
- FFmpeg development libraries (`brew install ffmpeg`)

## Installation

Add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "git@github.com:aalleato/libav-kit.git", branch: "main"),
]
```

Then add `LibAVKit` as a dependency to your target:

```swift
.target(name: "MyTarget", dependencies: [
    .product(name: "LibAVKit", package: "libav-kit"),
])
```

## API Overview

### Decoding

**Decoder** decodes audio files to raw PCM via a callback-based API. The `DecodedFrame` passed to the handler holds pointers into FFmpeg's internal frame buffer — valid only for the duration of the callback, zero-copy on the passthrough path.

```swift
let decoder = Decoder()
decoder.configure(outputFormat: .cdQuality)
try decoder.open(url: audioFileURL)

while true {
    do {
        try decoder.decodeNextFrame { frame in
            // frame.channelData: [UnsafePointer<Float>] — planar float PCM
            // frame.frameCount, frame.sampleRate, frame.channelCount
        }
    } catch is DecoderError {
        break // end of file
    }
}

decoder.close()
```

Properties available after `open()`: `duration`, `sampleRate`, `channels`, `bitrate`, `codecName`, `bitsPerSample`, `sourceFormat`.

### Encoding

**Encoder** encodes audio to compressed or lossless formats.

```swift
let encoder = Encoder()
let config = ConversionConfig(
    outputFormat: .flac,
    encodingSettings: .flac(FLACEncodingSettings(compressionLevel: 5))
)

try encoder.encode(
    inputURL: sourceFile,
    outputURL: outputFile,
    config: config,
    progress: { percent in print("\(Int(percent * 100))%") },
    isCancelled: { false }
)
```

Supported formats (runtime-checked via FFmpeg availability):

| Format | Lossless | Settings |
|--------|----------|----------|
| FLAC | Yes | Compression level (0-8) |
| ALAC | Yes | — |
| WAV | Yes | — |
| AIFF | Yes | — |
| WavPack | Yes | — |
| MP3 | No | CBR/VBR/ABR, bitrate, VBR quality |
| AAC | No | LC/HE-AAC/HE-AACv2, bitrate |
| Opus | No | Bitrate |
| Vorbis | No | Quality (0-10) |

### Metadata Reading

**MetadataReader** extracts metadata from audio files.

```swift
let reader = MetadataReader()
let metadata = try reader.read(url: audioFileURL)

print(metadata.title)       // "Song Title"
print(metadata.sampleRate)  // 44100
print(metadata.codec)       // "flac"
print(metadata.isAtmos)     // false
```

Reads: title, artist, album, albumArtist, year, trackNumber, discNumber, genre, duration, codec, bitrate, sampleRate, bitDepth, channels, coverArt, Atmos detection (E-AC-3 JOC, TrueHD).

### Tag Writing

**TagWriter** writes metadata to audio files via stream-copy remux (no re-encoding).

```swift
let writer = TagWriter()
let changes = MetadataChanges(
    title: "New Title",
    artistName: "New Artist",
    genre: "Jazz"
)

try writer.write(to: audioFileURL, changes: changes)
```

Supports extended tags (COMPOSER, CONDUCTOR, etc.) and custom tags. Atomic file replacement ensures crash safety.

### Cover Art Embedding

**CoverArtEmbedder** embeds or removes cover art using the C library (no CLI).

```swift
let embedder = CoverArtEmbedder()

// Embed
try embedder.embed(in: audioFileURL, imageData: jpegData, isOggContainer: false)

// Remove
try embedder.remove(from: audioFileURL)
```

Handles two embedding modes automatically:
- **OGG containers** (Opus, Vorbis): METADATA_BLOCK_PICTURE Vorbis comment
- **All others** (FLAC, MP3, AAC, etc.): Attached picture video stream

### Playback

**AudioPlayer** coordinates decoding and audio output. It depends only on Foundation — AVFoundation is not required.

```swift
let player = AudioPlayer()
try player.open(url: audioFileURL)

player.onStateChange = { state in print("State: \(state)") }
player.onProgress = { time in print("Position: \(time)s") }

player.play()
// player.pause(), player.seek(to: 30), player.stop()
```

**AudioOutput** is a protocol that abstracts the audio output backend. Implement it to plug in any audio system (Core Audio, SDL, unit test mock, etc.) without importing AVFoundation:

```swift
class MyCustomOutput: AudioOutput {
    func configure(sampleRate: Double, channels: Int) throws { /* ... */ }
    func start() throws { /* ... */ }
    func pause() { /* ... */ }
    func stop() { /* ... */ }
    func scheduleAudio(_ frame: DecodedFrame) {
        // Copy frame.channelData into your backend's native buffer.
        // No AVFoundation types involved.
    }
    func waitForCompletion(checkCancelled: () -> Bool) -> Bool { /* ... */ }
    var playbackPosition: TimeInterval { /* ... */ }
    var volume: Float { get { /* ... */ } set { /* ... */ } }
}

let player = AudioPlayer(output: MyCustomOutput())
```

**AVAudioEngineOutput** is the provided reference implementation that bridges `DecodedFrame` to `AVAudioPCMBuffer` internally — the only place in the library that touches AVFoundation.

## Models

### OutputFormat

Target codec for encoding. Each case maps to a file extension and container format.

### ConversionConfig

Complete conversion specification: output format, encoding settings, optional sample rate/bit depth/channel overrides, and destination path.

Factory methods for common configurations:

```swift
let mp3Config = ConversionConfig.MP3.cbr(bitrate: 320)
let mp3Vbr = ConversionConfig.MP3.vbr(quality: 2)
```

### EncodingSettings

Discriminator-based polymorphic enum with per-codec settings. Codable with a `"type"` key for JSON serialization:

```json
{"type": "mp3", "settings": {"bitrateMode": "vbr", "bitrateKbps": 320, "vbrQuality": 2}}
```

### AudioOutputFormat

Playback target format specifying sample rate, channel count, sample format, and interleaving.

### EncodingProfile

Named, reusable encoding configuration with output format, settings, and optional path template.

## Demo CLI (`libav-play`)

An internal CLI app that plays audio using LibAVKit. Build first, then run the binary directly for live progress updates (`swift run` buffers stdout, which prevents the progress line from updating in-place):

```bash
swift build
```

### File mode

Plays a local file using `AudioPlayer` with metadata display and progress tracking:

```bash
.build/debug/libav-play song.flac
.build/debug/libav-play --volume 0.5 song.mp3

# Quick test with a bundled fixture
.build/debug/libav-play Tests/LibAVKitTests/Fixtures/Parametric/flac-44100-stereo.flac
```

### STDIN mode

Pipes audio through `Decoder` + `AVAudioEngineOutput` directly. Requires `--format` since FFmpeg can't detect the codec from a pipe:

```bash
cat song.opus | .build/debug/libav-play --format opus -
ffmpeg -i input.wav -f flac - 2>/dev/null | .build/debug/libav-play --format flac -
```

### Options

| Option | Default | Description |
|--------|---------|-------------|
| `--volume` | 1.0 | Playback volume (0.0–1.0) |
| `--format` | — | Format hint for STDIN (`flac`, `mp3`, `opus`, etc.) |

Press Ctrl+C to stop playback.

## Testing

### Running Tests

```bash
# All tests (unit + BDD)
swift test

# BDD scenarios only
swift test --filter BDDTests

# Unit tests only (exclude BDD)
swift test --skip BDDTests
```

### BDD Contract Tests

83 Gherkin scenarios validate the public API across 4 feature files in `Features/` (at the project root, symlinked into the test target for SPM resource bundling):

| Feature | Scenarios | What it tests |
|---------|-----------|---------------|
| `encoding.feature` | 30 | All 9 target formats, hi-res, downsampling |
| `decoding.feature` | 30 | All 9 source codecs, sample rates, channels |
| `cover_art.feature` | 12 | Embed and remove across 6 supported codecs |
| `metadata.feature` | 11 | Tag write/read round-trip for all codecs |

Uses [PickleKit](https://github.com/nycjv321/pickle-kit) with the Swift Testing bridge (`GherkinTestScenario`).

### Filtering Scenarios

```bash
# Run scenarios by tag
CUCUMBER_TAGS=smoke swift test --filter BDDTests

# Exclude scenarios by tag
CUCUMBER_EXCLUDE_TAGS=slow swift test --filter BDDTests

# Run specific scenario by name
CUCUMBER_SCENARIOS="Encode CD-quality source" swift test --filter BDDTests
```

### HTML Reports

```bash
# Generate a Cucumber-style HTML report
PICKLE_REPORT=1 swift test --filter BDDTests

# Custom output path
PICKLE_REPORT=1 PICKLE_REPORT_PATH=build/report.html swift test --filter BDDTests
```

### Test Fixtures

Parametric audio fixtures in `Tests/LibAVKitTests/Fixtures/Parametric/` cover 36 files across 9 codecs (FLAC, WAV, ALAC, AIFF, WavPack, MP3, AAC, Vorbis, Opus) at CD and hi-res sample rates with mono and stereo variants. A `cover.png` fixture is used for art embedding tests.

## Architecture

```
LibAVKit
├── CFFmpeg (system library, internal — not re-exported)
├── Models/          Value types: OutputFormat, ConversionConfig, EncodingSettings, etc.
├── Decoding/        Decoder, MetadataReader, DecodedFrame
├── Encoding/        Encoder, EncoderConfig, EncoderMetadataWriter
├── Playback/        AudioPlayer, AudioOutput protocol, AVAudioEngineOutput
├── TagWriting/      TagWriter
├── ArtEmbedding/    CoverArtEmbedder
└── Utilities/       VorbisPictureBlock, CustomTagParser
```

The entire library is decoupled from AVFoundation. Only `AVAudioEngineOutput` imports it — every other file depends solely on Foundation and CFFmpeg. Custom `AudioOutput` implementations (Core Audio, SDL, test mocks) never need to import AVFoundation.

### Naming Convention

Public types use domain names without an "FFmpeg" prefix (`Decoder`, `Encoder`, `TagWriter`, `MetadataReader`, `CoverArtEmbedder`). Since every capability in this library is backed by FFmpeg, the prefix would be redundant. The `LibAVKit` module qualifier (`LibAVKit.Decoder`, `LibAVKit.Encoder`) disambiguates in the rare case of a naming collision. The one exception is `AVAudioEngineOutput`, which is prefixed to distinguish it as a concrete implementation of the `AudioOutput` protocol.

## License

MIT. See [LICENSE](LICENSE).

Note: This package links against FFmpeg, which is licensed under LGPL 2.1+ (or GPL depending on configuration). Ensure your FFmpeg build and usage comply with its license terms.
