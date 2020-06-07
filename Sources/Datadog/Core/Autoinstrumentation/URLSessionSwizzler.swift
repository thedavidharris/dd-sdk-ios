/*
 * Unless explicitly stated otherwise all files in this repository are licensed under the Apache License Version 2.0.
 * This product includes software developed at Datadog (https://www.datadoghq.com/).
 * Copyright 2019-2020 Datadog, Inc.
 */

import Foundation

internal protocol URLSessionInterceptor {
    func shouldIntercept(url: URL) -> Bool
    func shouldIntercept(request: URLRequest) -> Bool
    func intercept(request: URLRequest) -> URLRequest
    func notifyStart(of task: URLSessionTask)
    func intercept(response: URLResponse?, of task: URLSessionTask?) -> URLResponse?
}

/// Swizzles the `URLSession` by intercepting it's resource loading with `URLSessionInterceptor`.
internal class URLSessionSwizzler {
    private let interceptor: URLSessionInterceptor

    let dataTaskWithURLRequest: DataTaskWithURLRequest
    let dataTaskWithURL: DataTaskWithURL

    init(interceptor: URLSessionInterceptor) throws {
        self.interceptor = interceptor

        // prepare method swizzling
        self.dataTaskWithURLRequest = try DataTaskWithURLRequest()
        self.dataTaskWithURL = try DataTaskWithURL()

        // install interceptor in swizzled methods
        intercept(dataTaskWithURLRequest, using: interceptor)
        intercept(dataTaskWithURL, using: interceptor)
    }

    // MARK: - Declare swizzled methods

    typealias CompletionHandler = (Data?, URLResponse?, Error?) -> Void

    /// Swizzles the `URLSession..dataTask(with:completionHandler:)`
    class DataTaskWithURL: MethodSwizzler<
        /// Swizzle from:
        @convention(c) (URLSession, Selector, URL, @escaping CompletionHandler) -> URLSessionDataTask,
        /// to:
        @convention(block) (URLSession, URL, @escaping CompletionHandler) -> URLSessionDataTask
    > {
        init() throws {
            try super.init(
                selector: #selector(URLSession.dataTask(with:completionHandler:) as (URLSession) -> (URL, @escaping CompletionHandler) -> URLSessionDataTask),
                inClass: URLSession.self
            )
        }
    }

    /// Swizzles the `URLSession..dataTask(with:completionHandler:)`
    class DataTaskWithURLRequest: MethodSwizzler<
        /// Swizzle from:
        @convention(c) (URLSession, Selector, URLRequest, @escaping CompletionHandler) -> URLSessionDataTask,
        /// to:
        @convention(block) (URLSession, URLRequest, @escaping CompletionHandler) -> URLSessionDataTask
    > {
        init() throws {
            try super.init(
                selector: #selector(URLSession.dataTask(with:completionHandler:) as (URLSession) -> (URLRequest, @escaping CompletionHandler) -> URLSessionDataTask),
                inClass: URLSession.self
            )
        }
    }

    /// Swizzles the `URLSessionTask.resume()`
    class DataTaskResume: MethodSwizzler<
        /// Swizzle from:
        @convention(c) (URLSessionTask, Selector) -> Void,
        /// to:
        @convention(block) (URLSessionTask) -> Void
    > {
        init(taskClass: AnyClass) throws {
            try super.init(selector: #selector(URLSessionTask.resume), inClass: taskClass)
        }
    }

    // MARK: - Install `URLSessionInterceptor` in swizzled methods

    /// Intercepts `urlSession.dataTaskWithURLRequest(_:completion:)`
    private func intercept(_ method: DataTaskWithURLRequest, using interceptor: URLSessionInterceptor) {
        method.setNewImplementation { [weak self] session, request, completionHandler -> URLSessionDataTask in
            if interceptor.shouldIntercept(request: request) {
                let interceptedRequest = interceptor.intercept(request: request)
                weak var interceptedTask: URLSessionTask?

                let newCompletionHandler: CompletionHandler = { data, response, error in
                    completionHandler(data, interceptor.intercept(response: response, of: interceptedTask), error)
                }

                let task = method.originalImplementation(session, method.source.selector, interceptedRequest, newCompletionHandler)
                interceptedTask = task
                self?.interceptTaskIfNeeded(task, using: interceptor)
                return task
            } else {
                return method.originalImplementation(session, method.source.selector, request, completionHandler)
            }
        }
    }

    /// Intercepts `urlSession.dataTaskWithURL(_:completion:)`
    private func intercept(_ method: DataTaskWithURL, using interceptor: URLSessionInterceptor) {
        let dataTaskWithURLRequest = self.dataTaskWithURLRequest
        method.setNewImplementation { [weak self] session, url, completionHandler -> URLSessionDataTask in
            if interceptor.shouldIntercept(url: url) {
                let interceptedRequest = interceptor.intercept(request: session.urlRequest(with: url))
                weak var interceptedTask: URLSessionTask?

                let newCompletionHandler: CompletionHandler = { data, response, error in
                    completionHandler(data, interceptor.intercept(response: response, of: interceptedTask), error)
                }

                let task = dataTaskWithURLRequest.originalImplementation(session, method.source.selector, interceptedRequest, newCompletionHandler)
                interceptedTask = task
                self?.interceptTaskIfNeeded(task, using: interceptor)
                return task
            } else {
                return method.originalImplementation(session, method.source.selector, url, completionHandler)
            }
        }
    }

    private(set) var taskSwizzlingsByClassName: [String: DataTaskResume] = [:]

    /// Intercepts `urlSessionTask.resume()`. Because `task` may be assigned a different class at runtmie, here we we install the swizzling
    /// for its class only if it was not installed before.
    private func interceptTaskIfNeeded(_ task: URLSessionTask, using interceptor: URLSessionInterceptor) {
        objc_sync_enter(self) // synchronize `taskSwizzlingsByClassName` access
        defer { objc_sync_exit(self) }

        guard let taskRuntimeClass = object_getClass(task) else {
            return
        }

        let taskRuntimeClassName = NSStringFromClass(taskRuntimeClass)
        if taskSwizzlingsByClassName[taskRuntimeClassName] == nil {
            guard let dataTaskResume = try? DataTaskResume(taskClass: taskRuntimeClass) else {
                userLogger.error("Can't swizzle `.resume()` for task of class: \(taskRuntimeClassName)")
                return
            }

            dataTaskResume.setNewImplementation { task in
                interceptor.notifyStart(of: task)
                dataTaskResume.originalImplementation(task, dataTaskResume.source.selector)
            }

            taskSwizzlingsByClassName[taskRuntimeClassName] = dataTaskResume
        }
    }
}

private extension URLSession {
    func urlRequest(with url: URL) -> URLRequest {
        return URLRequest(
            url: url,
            cachePolicy: configuration.requestCachePolicy,
            timeoutInterval: configuration.timeoutIntervalForRequest
        )
    }
}
