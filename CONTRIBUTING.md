# Contributing to libav-kit

## Development Setup

**Prerequisites:**
- macOS 14.4+
- Swift 6.2+
- FFmpeg installed via Homebrew

```bash
brew install ffmpeg
git clone <repo-url>
cd libav-kit
swift build
swift test
```

## Feature Requirements

Every new feature or behavioral change **must** include corresponding Gherkin `.feature` files in `Features/`. The BDD workflow is:

1. Write scenarios in a `.feature` file under `Features/`
2. Add step definitions in `Tests/LibAVKitTests/Steps/` (Given → `SetupSteps`, When → `ActionSteps`, Then → `VerificationSteps`)
3. Implement the feature in `Sources/LibAVKit/`
4. Verify all scenarios pass with `swift test --filter BDDTests`

Feature files are symlinked into the test target for SPM resource bundling — do not place them directly in `Tests/`.

## Testing

All tests must pass before submitting a PR:

```bash
# Run everything
swift test

# BDD scenarios only
swift test --filter BDDTests

# Unit tests only
swift test --skip BDDTests

# Filter by tag or scenario name
CUCUMBER_TAGS=smoke swift test --filter BDDTests
CUCUMBER_SCENARIOS="Encode CD-quality source" swift test --filter BDDTests
```

- New step definitions go in the appropriate file under `Tests/LibAVKitTests/Steps/`
- New test fixtures go in `Tests/LibAVKitTests/Fixtures/`
- Fixtures are never modified in-place — tests copy them to a temp directory

## Commit Messages

Use [conventional commits](https://www.conventionalcommits.org/):

- `feat:` — new feature
- `fix:` — bug fix
- `chore:` — maintenance tasks
- `docs:` — documentation changes
- `refactor:` — code restructuring without behavior change
- `test:` — adding or updating tests

## Pull Requests

- Keep PRs focused on a single concern
- Include a description of what changed and why
- Link related issues if applicable
- Ensure all tests pass

## Code Style

Follow existing patterns in the codebase:

- Value types for models
- `Sendable` conformance where appropriate
- Do not re-export `CFFmpeg` — only the Swift API in `LibAVKit` is public
- Keep the public API surface minimal

## Adding New Formats

Adding format support is a common extension point. The general steps are:

1. Add the format to the `OutputFormat` enum
2. Implement encoder/decoder support in `Sources/LibAVKit/`
3. Add Gherkin scenarios in `Features/` covering the new format
4. Add parametric test fixtures to `Tests/LibAVKitTests/Fixtures/`
