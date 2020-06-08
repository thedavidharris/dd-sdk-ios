/*
 * Unless explicitly stated otherwise all files in this repository are licensed under the Apache License Version 2.0.
 * This product includes software developed at Datadog (https://www.datadoghq.com/).
 * Copyright 2019-2020 Datadog, Inc.
 */

import XCTest
@testable import Datadog

private class URLSessionInterceptorMock: URLSessionInterceptor {
    let shouldInterceptURL: Bool
    let shouldInterceptRequest: Bool

    init(shouldIntercept: Bool) {
        shouldInterceptURL = shouldIntercept
        shouldInterceptRequest = shouldIntercept
    }

    // MARK: - Recorded values

    var interceptedRequest: URLRequest?
    var startedTask: URLSessionTask?
    var interceptedResponse: (URLResponse?, URLSessionTask?)?

    // MARK: - URLSessionInterceptor

    func shouldIntercept(url: URL) -> Bool { shouldInterceptURL }
    func shouldIntercept(request: URLRequest) -> Bool { shouldInterceptRequest }

    func intercept(request: URLRequest) -> URLRequest {
        interceptedRequest = request
        return request
    }

    func notifyStart(of task: URLSessionTask) {
        startedTask = task
    }

    func intercept(response: URLResponse?, of task: URLSessionTask?) -> URLResponse? {
        interceptedResponse = (response, task)
        return response
    }
}

extension URLSessionSwizzler {
    func unswizzle() {
        method_setImplementation(dataTaskWithURL.method, dataTaskWithURL.originalImplementationPointer)
        method_setImplementation(dataTaskWithURLRequest.method, dataTaskWithURLRequest.originalImplementationPointer)
        taskSwizzlingsByClassName.values.forEach { taskSwizzler in
            method_setImplementation(taskSwizzler.method, taskSwizzler.originalImplementationPointer)
        }
    }
}

class URLSessionSwizzlerTests: XCTestCase {
    func testAcceptedURLRequestIsProcessedByTheInterceptor() throws {
        let serverMock = ServerMock(delivery: .success(response: .mockResponseWith(statusCode: 200), data: .mockAny()))
        let taskCompletion = expectation(description: "Task did complete")

        // Given
        let mockInterceptor = URLSessionInterceptorMock(shouldIntercept: true) // accept
        let sessionSwizzler = try URLSessionSwizzler(interceptor: mockInterceptor)

        // When
        let request = URLRequest(url: URL(string: "http://foo.bar")!)
        let task = serverMock.urlSession.dataTask(with: request) { _, _, _ in
            taskCompletion.fulfill()
        }
        task.resume()

        waitForExpectations(timeout: 1, handler: nil)

        // Then
        XCTAssertTrue(mockInterceptor.interceptedRequest == request)
        XCTAssertTrue(mockInterceptor.startedTask === task)
        XCTAssertEqual((mockInterceptor.interceptedResponse?.0 as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(mockInterceptor.interceptedResponse?.1 === task)

        serverMock.waitFor(requestsCompletion: 1)
        sessionSwizzler.unswizzle()
    }

    func testAcceptedURLIsProcessedByTheInterceptor() throws {
        let serverMock = ServerMock(delivery: .success(response: .mockResponseWith(statusCode: 200), data: .mockAny()))
        let taskCompletion = expectation(description: "Task did complete")

        // Given
        let mockInterceptor = URLSessionInterceptorMock(shouldIntercept: true) // accept
        let sessionSwizzler = try URLSessionSwizzler(interceptor: mockInterceptor)

        // When
        let url = URL(string: "http://foo.bar")!
        let task = serverMock.urlSession.dataTask(with: url) { _, _, _ in
            taskCompletion.fulfill()
        }
        task.resume()

        waitForExpectations(timeout: 1, handler: nil)

        // Then
        XCTAssertEqual(mockInterceptor.interceptedRequest?.url, url)
        XCTAssertTrue(mockInterceptor.startedTask === task)
        XCTAssertEqual((mockInterceptor.interceptedResponse?.0 as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(mockInterceptor.interceptedResponse?.1 === task)

        serverMock.waitFor(requestsCompletion: 1)
        sessionSwizzler.unswizzle()
    }

    func testUnacceptedURLRequestIsNotProcessedByTheInterceptor() throws {
        let serverMock = ServerMock(delivery: .success(response: .mockResponseWith(statusCode: 200), data: .mockAny()))
        let taskCompletion = expectation(description: "Task did complete")

        // Given
        let mockInterceptor = URLSessionInterceptorMock(shouldIntercept: false) // do not accept
        let sessionSwizzler = try URLSessionSwizzler(interceptor: mockInterceptor)

        // When
        let request = URLRequest(url: URL(string: "http://foo.bar")!)
        let task = serverMock.urlSession.dataTask(with: request) { _, _, _ in
            taskCompletion.fulfill()
        }
        task.resume()

        waitForExpectations(timeout: 1, handler: nil)

        // Then
        XCTAssertNil(mockInterceptor.interceptedRequest)
        XCTAssertNil(mockInterceptor.startedTask)
        XCTAssertNil(mockInterceptor.interceptedResponse)

        serverMock.waitFor(requestsCompletion: 1)
        sessionSwizzler.unswizzle()
    }

    func testUnacceptedURLIsNotProcessedByTheInterceptor() throws {
        let serverMock = ServerMock(delivery: .success(response: .mockResponseWith(statusCode: 200), data: .mockAny()))
        let taskCompletion = expectation(description: "Task did complete")

        // Given
        let mockInterceptor = URLSessionInterceptorMock(shouldIntercept: false) // do not accept
        let sessionSwizzler = try URLSessionSwizzler(interceptor: mockInterceptor)

        // When
        let url = URL(string: "http://foo.bar")!
        let task = serverMock.urlSession.dataTask(with: url) { _, _, _ in
            taskCompletion.fulfill()
        }
        task.resume()

        waitForExpectations(timeout: 1, handler: nil)

        // Then
        XCTAssertNil(mockInterceptor.interceptedRequest)
        XCTAssertNil(mockInterceptor.startedTask)
        XCTAssertNil(mockInterceptor.interceptedResponse)

        serverMock.waitFor(requestsCompletion: 1)
        sessionSwizzler.unswizzle()
    }
}
