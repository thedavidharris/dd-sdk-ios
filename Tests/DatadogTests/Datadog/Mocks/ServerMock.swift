/*
 * Unless explicitly stated otherwise all files in this repository are licensed under the Apache License Version 2.0.
 * This product includes software developed at Datadog (https://www.datadoghq.com/).
 * Copyright 2019-2020 Datadog, Inc.
 */

import Foundation
import XCTest
@testable import Datadog

private class ServerMockProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        return true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        // By the time this `canonicalRequest(for:)` is called, the original `URLRequest` is
        // already transformed in `URLSession` by encoding `httpBody` into a stream and
        // setting `Content-Length` HTTP header. This means that the `request` is not the one
        // that we originally sent. Here, we transform it back from `httpBodyStream` to `httpBody`.
        if let httpBodyStream = request.httpBodyStream {
            let contentLength = Int(request.allHTTPHeaderFields!["Content-Length"]!)!

            var canonicalRequest = URLRequest(url: request.url!)
            canonicalRequest.httpMethod = request.httpMethod
            canonicalRequest.allHTTPHeaderFields = request.allHTTPHeaderFields
            canonicalRequest.httpBody = httpBodyStream.readAllBytes(expectedSize: contentLength)
            return canonicalRequest
        } else {
            return request
        }
    }

    override func startLoading() {
        guard let serverMock = ServerMock.activeInstance else {
            preconditionFailure("Request was started while no `ServerMock` instance is active.")
        }

        if let response = serverMock.mockedResponse {
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        }
        if let data = serverMock.mockedData {
            client?.urlProtocol(self, didLoad: data)
        }
        if let error = serverMock.mockedError {
            client?.urlProtocol(self, didFailWithError: error)
        }

        client?.urlProtocolDidFinishLoading(self)

        DispatchQueue.main.async {
            serverMock.record(newRequest: self.request)
        }
    }

    override func stopLoading() {
        precondition(ServerMock.activeInstance != nil, "Request was stopped while no `ServerMock` instance is active.")
    }
}

/// All unit tests use this shared `URLSession`.
private let sharedURLSession: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ServerMockProtocol.self]
    return URLSession(configuration: configuration)
}()

class ServerMock {
    static weak var activeInstance: ServerMock?

    /// `URLSession` to be used for all networking that should be mocked by this `ServerMock`.
    let urlSession: URLSession = sharedURLSession
    private let queue = DispatchQueue(label: "com.datadoghq.ServerMock-\(UUID().uuidString)")

    fileprivate let mockedResponse: HTTPURLResponse?
    fileprivate let mockedData: Data?
    fileprivate let mockedError: Error?

    enum Delivery {
        case success(response: HTTPURLResponse, data: Data = .mockAny())
        case failure(error: Error)
    }

    init(delivery: Delivery) {
        switch delivery {
        case let .success(response: response, data: data):
            self.mockedResponse = response
            self.mockedData = data
            self.mockedError = nil
        case let .failure(error):
            self.mockedResponse = nil
            self.mockedData = nil
            self.mockedError = error
        }
        precondition(Thread.isMainThread, "`ServerMock` should be initialized on the main thread.")
        precondition(ServerMock.activeInstance == nil, "Only one active instance of `ServerMock` is allowed at a time.")
        ServerMock.activeInstance = self
    }

    deinit {
        /// Following precondition will fail when `ServerMock` instance was retained ONLY by existing HTTP request callback.
        /// Such case means a programmer error, because the existing callback can impact result of the next unit test, causing a flakiness.
        ///
        /// If that happens, make sure the `ServerMock` processess all calbacks before it gets deallocated:
        ///
        ///     func testXYZ() {
        ///        let server = ServerMock(...)
        ///
        ///        // ... testing
        ///
        ///        server.waitFor(requestsCompletion:)
        ///        // <-- no reference to `server` exists and it processed all callbacks, so it will be safely deallocated
        ///     }
        ///
        /// NOTE: one of the `wait*` methods **must be called** within the test using `ServerMock`.
        ///
        precondition(Thread.isMainThread, "`ServerMock` should be deinitialized on the main thread.")
    }

    fileprivate func record(newRequest: URLRequest) {
        queue.async {
            self.requests.append(newRequest)
            self.waitAndReturnRequestsExpectation?.fulfill()
        }
    }

    private var requests: [URLRequest] = []
    private var waitAndReturnRequestsExpectation: XCTestExpectation?

    // MARK: - Waiting for total number of requests

    /// Waits until given number of request callbacks is completed (in total for this instance of `ServerMock`) and returns that requests.
    /// Passing no `timeout` will result with picking the recommended timeout for unit tests.
    /// Calling this method guarantees also that no callbacks are leaked inside `URLSession`, which prevents tests flakiness.
    func waitAndReturnRequests(count: UInt, timeout: TimeInterval? = nil, file: StaticString = #file, line: UInt = #line) -> [URLRequest] {
        precondition(waitAndReturnRequestsExpectation == nil, "The `ServerMock` is already waiting on `waitAndReturnRequests`.")

        let expectation = XCTestExpectation(description: "Receive \(count) requests.")
        if count > 0 {
            expectation.expectedFulfillmentCount = Int(count)
        } else {
            expectation.isInverted = true
        }

        queue.sync {
            self.waitAndReturnRequestsExpectation = expectation
            self.requests.forEach { _ in expectation.fulfill() } // fulfill already recorded
        }

        let timeout = timeout ?? recommendedTimeoutFor(numberOfRequestsMade: max(count, 1))
        let result = XCTWaiter().wait(for: [expectation], timeout: timeout)

        switch result {
        case .completed:
            break
        case .incorrectOrder, .interrupted:
            fatalError("Can't happen.")
        case .timedOut:
            XCTFail("Exceeded timeout of \(timeout)s with receiving \(requests.count) out of \(count) expected requests.", file: file, line: line)
            // Return array of dummy requests, so the crash will happen leter in the test code, properly
            // printing the above error.
            return Array(repeating: .mockAny(), count: Int(count))
        case .invertedFulfillment:
            XCTFail("\(requests.count) requests were sent, but not expected.", file: file, line: line)
            // Return array of dummy requests, so the crash will happen leter in the test code, properly
            // printing the above error.
            return queue.sync { requests }
        @unknown default:
            fatalError()
        }

        return queue.sync { requests }
    }

    /// Waits until given number of request callbacks is completed (in total for this instance of `ServerMock`).
    /// Passing no `timeout` will result with picking the recommended timeout for unit tests.
    /// Calling this method guarantees that no callbacks are leaked inside `URLSession`, which prevents tests flakiness.
    func waitFor(requestsCompletion requestsCount: UInt, timeout: TimeInterval? = nil, file: StaticString = #file, line: UInt = #line) {
        _ = waitAndReturnRequests(count: requestsCount, timeout: timeout)
    }

    /// Waits an arbitrary amount of time and asserts that no requests were sent to `ServerMock`. 
    func waitAndAssertNoRequestsSent(file: StaticString = #file, line: UInt = #line) {
        waitFor(requestsCompletion: 0)
    }

    // MARK: - Utils

    /// Returns recommended timeout for delivering given number of requests if `.mockUnitTestsPerformancePreset()` is used for upload.
    func recommendedTimeoutFor(numberOfRequestsMade: UInt) -> TimeInterval {
        let uploadPerformanceForTests = UploadPerformanceMock.veryQuick
        // Set the timeout to 40 times more than expected.
        // In `RUMM-311` we observed 0.66% of flakiness for 150 test runs on CI with arbitrary value of `20`.
        return uploadPerformanceForTests.defaultUploadDelay * Double(numberOfRequestsMade) * 40
    }
}

// MARK: - Feature helpers

extension ServerMock {
    func waitAndReturnLogMatchers(count: UInt, file: StaticString = #file, line: UInt = #line) throws -> [LogMatcher] {
        try waitAndReturnRequests(
            count: count,
            timeout: recommendedTimeoutFor(numberOfRequestsMade: count),
            file: file,
            line: line
        )
            .map { request in try request.httpBody.unwrapOrThrow() }
            .flatMap { requestBody in try LogMatcher.fromArrayOfJSONObjectsData(requestBody, file: file, line: line) }
    }
}

// MARK: - Tracing feature helpers

extension ServerMock {
    func waitAndReturnSpanMatchers(count: UInt, file: StaticString = #file, line: UInt = #line) throws -> [SpanMatcher] {
        return try waitAndReturnRequests(
            count: count,
            timeout: recommendedTimeoutFor(numberOfRequestsMade: count),
            file: file,
            line: line
        )
        .map { request in try request.httpBody.unwrapOrThrow() }
        .flatMap { requestBody in
            try SpanMatcher.fromNewlineSeparatedJSONObjectsData(requestBody)
        }
    }
}

// MARK: - RUM feature helpers

extension ServerMock {
    func waitAndReturnRUMEventMatchers(count: UInt, file: StaticString = #file, line: UInt = #line) throws -> [RUMEventMatcher] {
        return try waitAndReturnRequests(
            count: count,
            timeout: recommendedTimeoutFor(numberOfRequestsMade: count),
            file: file,
            line: line
        )
        .map { request in try request.httpBody.unwrapOrThrow() }
        .flatMap { requestBody in
            try RUMEventMatcher.fromNewlineSeparatedJSONObjectsData(requestBody)
        }
    }
}
