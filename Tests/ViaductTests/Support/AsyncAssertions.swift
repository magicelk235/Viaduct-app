import XCTest

/// XCTAssertThrowsError for an expression that has to be awaited. Hands the
/// error to `handler` when there is one.
func XCTAssertThrowsErrorAsync<T>(_ expression: @autoclosure () async throws -> T,
                                  _ message: @autoclosure () -> String = "",
                                  file: StaticString = #filePath, line: UInt = #line,
                                  _ handler: (Error) -> Void = { _ in }) async {
    do {
        _ = try await expression()
        let detail = message()
        XCTFail(detail.isEmpty ? "Expected an error, nothing was thrown" : detail, file: file, line: line)
    } catch {
        handler(error)
    }
}
