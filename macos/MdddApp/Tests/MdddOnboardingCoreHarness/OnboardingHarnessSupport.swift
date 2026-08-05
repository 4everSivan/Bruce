import Foundation
@testable import MdddOnboardingCore

enum CoreTestFailure: Error, CustomStringConvertible {
    case expectation(String)

    var description: String {
        switch self {
        case .expectation(let message):
            return message
        }
    }
}

@MainActor
func coreExpect(
    _ condition: @autoclosure () -> Bool,
    _ message: String
) throws {
    if !condition() {
        throw CoreTestFailure.expectation(message)
    }
}

// MARK: - Test helper

final class TestFileManager: FileManager {
    let executables: Set<String>
    init(executables: [String]) {
        self.executables = Set(executables)
    }
    override func isExecutableFile(atPath path: String) -> Bool {
        executables.contains(path)
    }
}

