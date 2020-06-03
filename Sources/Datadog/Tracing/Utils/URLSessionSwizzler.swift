/*
 * Unless explicitly stated otherwise all files in this repository are licensed under the Apache License Version 2.0.
 * This product includes software developed at Datadog (https://www.datadoghq.com/).
 * Copyright 2019-2020 Datadog, Inc.
 */

import Foundation

/// Block type to hook into URLSession methods:
/// dataTaskWithURL:completion: and dataTaskWithRequest:completion:
/// Takes original URLRequest and returns modified URLRequest with TaskObserver
internal typealias RequestInterceptor = (URLRequest) -> InterceptionResult?
internal typealias InterceptionResult = (modifiedRequest: URLRequest, taskObserver: TaskObserver)

/// Block to be executed at task starting and completion by URLSessionSwizzler
/// starting event is passed at task.resume()
/// completed event is passed when task's completion handler is being executed
internal typealias TaskObserver = (TaskObservationEvent) -> Void
internal enum TaskObservationEvent: Equatable {
    case starting
    case completed
}

// MARK: - Private

internal enum URLSessionSwizzler {
    static var hasSwizzledBefore = false

    static func swizzleOnce(using interceptor: @escaping RequestInterceptor) throws {
        if hasSwizzledBefore {
            return
        }
        defer { hasSwizzledBefore = true }

        guard let dataTaskWithURL = DataTaskWithURL(), let dataTaskWithURLRequest = DataTaskWithURLRequest() else {
            throw InternalError(description: "URLSession methods could not be found, thus not swizzled")
        }

        dataTaskWithURL.intercept(using: interceptor, byRedirectingTo: dataTaskWithURLRequest)
        dataTaskWithURLRequest.intercept(using: interceptor)
    }

    typealias CompletionHandler = (Data?, URLResponse?, Error?) -> Void

    private struct DataTaskWithURL {
        typealias TypedIMP = @convention(c) (URLSession, Selector, URL, @escaping CompletionHandler) -> URLSessionDataTask
        private typealias TypedBlockIMP = @convention(block) (URLSession, URL, @escaping CompletionHandler) -> URLSessionDataTask

        private let subjectClass = URLSession.self
        private let selector = #selector(URLSession.dataTask(with:completionHandler:) as (URLSession) -> (URL, @escaping CompletionHandler) -> URLSessionDataTask)

        let swizzler: MethodSwizzler

        init?() {
            guard let swizzler = MethodSwizzler.for(selector: selector, inClass: subjectClass) else {
                return nil
            }
            self.swizzler = swizzler
        }

        func intercept(using interceptor: @escaping RequestInterceptor, byRedirectingTo dataTaskWithURLRequest: DataTaskWithURLRequest) {
            let sel = selector
            let typedOriginalImp: TypedIMP = swizzler.currentImplementation()

            let typedRedirectedImp: DataTaskWithURLRequest.TypedIMP
            typedRedirectedImp = dataTaskWithURLRequest.swizzler.originalImplementation()

            let newImpBlock: TypedBlockIMP = { impSelf, impURL, impCompletion -> URLSessionDataTask in
                if let interceptionResult = interceptor(impSelf.urlRequest(with: impURL)) {
                    weak var blockTask: URLSessionDataTask? = nil
                    let modifiedCompletion: CompletionHandler = { origData, origResponse, origError in
                        impCompletion(origData, origResponse, origError)
                        blockTask?.payload?(.completed)
                    }
                    let task = typedRedirectedImp(impSelf, sel, interceptionResult.modifiedRequest, modifiedCompletion)
                    task.payload = interceptionResult.taskObserver
                    DataTaskResume(task: task)?.observe()
                    blockTask = task
                    return task
                }

                return typedOriginalImp(impSelf, sel, impURL, impCompletion)
            }
            let newImp: IMP = imp_implementationWithBlock(newImpBlock)
            swizzler.swizzle(to: newImp)
        }
    }

    private struct DataTaskWithURLRequest {
        typealias TypedIMP = @convention(c) (URLSession, Selector, URLRequest, @escaping CompletionHandler) -> URLSessionDataTask
        private typealias TypedBlockIMP = @convention(block) (URLSession, URLRequest, @escaping CompletionHandler) -> URLSessionDataTask

        private let subjectClass = URLSession.self
        private let selector = #selector(URLSession.dataTask(with:completionHandler:) as (URLSession) -> (URLRequest, @escaping CompletionHandler) -> URLSessionDataTask)

        let swizzler: MethodSwizzler

        init?() {
            guard let swizzler = MethodSwizzler.for(selector: selector, inClass: subjectClass) else {
                return nil
            }
            self.swizzler = swizzler
        }

        func intercept(using interceptor: @escaping RequestInterceptor) {
            let sel = selector
            let typedOriginalImp: TypedIMP = swizzler.currentImplementation()

            let newImpBlock: TypedBlockIMP = { impSelf, impURLRequest, impCompletion -> URLSessionDataTask in
                if let interceptionResult = interceptor(impURLRequest) {
                    weak var blockTask: URLSessionDataTask? = nil

                    let modifiedCompletion: CompletionHandler = { origData, origResponse, origError in
                        impCompletion(origData, origResponse, origError)
                        blockTask?.payload?(.completed)
                    }

                    let task = typedOriginalImp(impSelf, sel, interceptionResult.modifiedRequest, modifiedCompletion)
                    task.payload = interceptionResult.taskObserver
                    DataTaskResume(task: task)?.observe()
                    blockTask = task
                    return task
                }
                return typedOriginalImp(impSelf, sel, impURLRequest, impCompletion)
            }

            let newImp: IMP = imp_implementationWithBlock(newImpBlock)
            swizzler.swizzle(to: newImp)
        }
    }

    private struct DataTaskResume {
        private typealias TypedIMP = @convention(c) (URLSessionTask, Selector) -> Void
        private typealias TypedBlockIMP = @convention(block) (URLSessionTask) -> Void

        private let selector = #selector(URLSessionTask.resume)

        let swizzler: MethodSwizzler

        init?(task: URLSessionTask) {
            // NOTE: RUMM-452 `URLSessionTask.resume` is not called by its subclasses.
            // Therefore, we swizzle this method in the subclass (object_getClass(task)).
            guard let taskClass = object_getClass(task), let swizzler = MethodSwizzler.for(selector: selector, inClass: taskClass) else {
                return nil
            }
            self.swizzler = swizzler
        }

        func observe() {
            let sel = selector
            let typedOriginalImp: TypedIMP = swizzler.currentImplementation()

            let newImpBlock: TypedBlockIMP = { impSelf in
                impSelf.payload?(.starting)
                return typedOriginalImp(impSelf, sel)
            }

            let newImp = imp_implementationWithBlock(newImpBlock)
            swizzler.swizzleIfNotSwizzled(to: newImp)
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

/// payload is a TaskObserver, executed in task.resume() and completion
private extension URLSessionTask {
    private static var payloadAssociationKey: UInt8 = 0
    var payload: TaskObserver? {
        get { objc_getAssociatedObject(self, &Self.payloadAssociationKey) as? TaskObserver }
        set { objc_setAssociatedObject(self, &Self.payloadAssociationKey, newValue, .OBJC_ASSOCIATION_RETAIN) }
    }
}
