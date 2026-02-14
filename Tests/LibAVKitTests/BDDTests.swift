import Foundation
import PickleKit
import Testing

/// BDD test runner for libav-kit contract tests.
///
/// Loads all `.feature` files from the Features resource directory and runs
/// each expanded scenario as a parameterized Swift Testing test case.
///
/// Serialized because step definitions share mutable state via `TestContext`.
@Suite(.serialized)
struct BDDTests {
    static let allScenarios = GherkinTestScenario.scenarios(
        bundle: .module,
        subdirectory: "Features"
    )

    @Test(arguments: BDDTests.allScenarios)
    func scenario(_ test: GherkinTestScenario) async throws {
        let result = try await test.run(stepDefinitions: [
            SetupSteps.self,
            ActionSteps.self,
            VerificationSteps.self,
            PlaybackSteps.self,
            RawEncodingSteps.self,
        ])

        #expect(result.passed, "Scenario '\(test.description)' failed: \(failureDetails(result))")
    }

    private func failureDetails(_ result: ScenarioResult) -> String {
        let failedSteps = result.stepResults.filter { $0.status != .passed }
        if failedSteps.isEmpty { return "unknown" }

        return failedSteps.map { step in
            "\(step.keyword) \(step.text): \(step.error ?? step.status.rawValue)"
        }.joined(separator: "; ")
    }
}
