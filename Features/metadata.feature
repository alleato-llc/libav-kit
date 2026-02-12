Feature: Metadata Writing
  LibAVKit writes metadata tags to audio files and preserves audio properties.
  Tags are written via TagWriter (stream-copy remux) and read back
  via MetadataReader to verify round-trip correctness.

  Scenario Outline: Write and read metadata tags
    Given a "<codec>" file at "<source_fixture>"
    When I write metadata with title "Glass Meridian" artist "Velvet Prism" album "Neon Cathedral" track 3 disc 1 genre "Electronic" year 2024
    Then the metadata title is "Glass Meridian"
    And the metadata artist is "Velvet Prism"
    And the metadata album is "Neon Cathedral"
    And the metadata track number is 3
    And the metadata disc number is 1
    And the metadata genre is "Electronic"
    And the metadata year is 2024
    And the sample rate is <expected_sample_rate>
    And the channel count is <expected_channels>

    Examples:
      | codec   | source_fixture                | expected_sample_rate | expected_channels |
      | FLAC    | flac/cd-16bit-stereo.flac     | 44100                | 2                 |
      | MP3     | mp3/cd-stereo.mp3             | 44100                | 2                 |
      | AAC     | aac/cd-stereo.m4a             | 44100                | 2                 |
      | ALAC    | alac/cd-16bit-stereo.m4a      | 44100                | 2                 |
      | Opus    | opus/cd-stereo.opus           | 48000                | 2                 |
      | Vorbis  | vorbis/cd-stereo.ogg          | 44100                | 2                 |
      | WavPack | wv/cd-16bit-stereo.wv         | 44100                | 2                 |

  Scenario: Write metadata to WAV preserves supported fields
    Given a "WAV" file at "wav/cd-16bit-stereo.wav"
    When I write metadata with title "Glass Meridian" artist "Velvet Prism" album "Neon Cathedral" track 3 disc 1 genre "Electronic" year 2024
    Then the metadata title is "Glass Meridian"
    And the metadata artist is "Velvet Prism"
    And the metadata album is "Neon Cathedral"
    And the metadata track number is 3
    And the metadata genre is "Electronic"
    And the metadata year is 2024
    And the sample rate is 44100
    And the channel count is 2

  Scenario: Write metadata to AIFF preserves title
    Given a "AIFF" file at "aiff/cd-16bit-stereo.aiff"
    When I write metadata with title "Glass Meridian" artist "Velvet Prism" album "Neon Cathedral" track 3 disc 1 genre "Electronic" year 2024
    Then the metadata title is "Glass Meridian"
    And the sample rate is 44100
    And the channel count is 2

  Scenario: Write to non-existent file throws error
    Given a non-existent file at "/nonexistent/path/to/file.flac"
    When I attempt to write metadata
    Then the write fails with an error
