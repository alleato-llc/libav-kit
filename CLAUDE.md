# CLAUDE.md — libav-kit

## What This Is

A Swift package wrapping FFmpeg's C libraries for audio decoding, encoding, metadata reading/writing, and cover art embedding. Uses the C API directly — no CLI shelling.

## Build & Test

```bash
# Prerequisites
brew install ffmpeg

# Build
swift build

# All tests (unit + BDD)
swift test

# BDD scenarios only
swift test --filter BDDTests

# Unit tests only
swift test --skip BDDTests

# Filter by tag / scenario name
CUCUMBER_TAGS=smoke swift test --filter BDDTests
CUCUMBER_SCENARIOS="Encode CD-quality source" swift test --filter BDDTests

# HTML report
PICKLE_REPORT=1 swift test --filter BDDTests
```

## Project Structure

```
├── Sources/
│   ├── CFFmpeg/          # System library wrapper (module.modulemap + shim.h)
│   └── LibAVKit/         # Public Swift API
│       ├── Models/       # OutputFormat, ConversionConfig, EncodingSettings, etc.
│       ├── Decoding/     # Decoder, MetadataReader, DecodedFrame
│       ├── Encoding/     # Encoder, EncoderConfig, EncoderMetadataWriter
│       ├── Playback/     # AudioPlayer, AudioOutput protocol, AVAudioEngineOutput
│       ├── TagWriting/   # TagWriter (stream-copy remux, no re-encoding)
│       ├── ArtEmbedding/ # CoverArtEmbedder
│       └── Utilities/    # VorbisPictureBlock, CustomTagParser
├── Features/             # Gherkin .feature files (symlinked into test target)
└── Tests/LibAVKitTests/
    ├── BDDTests.swift    # PickleKit scenario runner
    ├── Steps/            # Given/When/Then step definitions
    ├── Fixtures/         # 36 parametric audio files + cover.png
    └── Support/          # TemporaryDirectory helper
```

## Key Conventions

- **No FFmpeg prefix** — public types use domain names (`Decoder`, `Encoder`, `TagWriter`, etc.). The module qualifier `LibAVKit.Decoder` disambiguates if needed.
- **No AVFoundation dependency** — only `AVAudioEngineOutput` imports it; everything else depends on Foundation and CFFmpeg
- **Swift 6.2+, macOS 14.4+**
- **CFFmpeg is internal** — only the Swift API in LibAVKit is public
- **BDD tests use PickleKit** with Gherkin feature files and regex-based step matching
- **Tests run serialized** — step definitions share mutable state via `TestContext.shared`
- **Fixtures are never modified** — tests copy them to a temp dir with UUID names
- **Atomic file operations** — tag writer uses rename for crash safety
- **Discriminator-based Codable** — EncodingSettings uses `{"type": "...", "settings": {...}}`
- **Feature files live at project root** (`Features/`) and are symlinked into the test target for SPM resource bundling

## Supported Formats

Lossless: FLAC, ALAC, WAV, AIFF, WavPack
Lossy: MP3 (CBR/VBR/ABR), AAC (LC/HE-AAC/HE-AACv2), Opus, Vorbis

## Test Architecture

83 Gherkin scenarios across 4 feature files (encoding, decoding, cover_art, metadata). Step definitions are split into SetupSteps (Given), ActionSteps (When), and VerificationSteps (Then). EncodingSettingsResolver maps feature table keys to EncodingSettings values.
