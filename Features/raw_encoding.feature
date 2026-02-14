Feature: Raw Encoding
  Encode programmatically-generated audio samples to file.

  Scenario: Encode mono sine wave to FLAC
    Given a 440Hz sine wave at 44100Hz sample rate for 1 second with 1 channel
    When I encode the raw samples to FLAC at the output path
    Then the output file exists
    And the output has codec "flac"
    And the output has sample rate 44100
    And the output has 1 channel
    And the output duration is approximately 1.0 seconds

  Scenario: Encode stereo sine wave to FLAC
    Given a 440Hz sine wave at 44100Hz sample rate for 2 seconds with 2 channels
    When I encode the raw samples to FLAC at the output path
    Then the output file exists
    And the output has 2 channels
    And the output duration is approximately 2.0 seconds

  Scenario: Encode with metadata
    Given a 440Hz sine wave at 44100Hz sample rate for 1 second with 1 channel
    And metadata with title "Test Tone" and artist "Generator"
    When I encode the raw samples to FLAC at the output path
    Then the output metadata title is "Test Tone"
    And the output metadata artist is "Generator"
