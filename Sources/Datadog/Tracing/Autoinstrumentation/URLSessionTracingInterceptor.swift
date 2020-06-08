/*
 * Unless explicitly stated otherwise all files in this repository are licensed under the Apache License Version 2.0.
 * This product includes software developed at Datadog (https://www.datadoghq.com/).
 * Copyright 2019-2020 Datadog, Inc.
 */

import Foundation
import OpenTracing

internal struct URLSessionTracingInterceptor: URLSessionInterceptor {
    let tracingFeature: TracingFeature
    let acceptedURLs: [URL]

    func shouldIntercept(url: URL) -> Bool {
        return acceptedURLs.contains { url.absoluteString.contains($0.absoluteString) }
    }

    func shouldIntercept(request: URLRequest) -> Bool {
        guard let url = request.url else {
            return false
        }
        return acceptedURLs.contains { url.absoluteString.contains($0.absoluteString) }
    }

    func intercept(request: URLRequest) -> URLRequest {
        var mutableRequest = request

        mutableRequest.setValue(
            String(tracingFeature.tracingUUIDGenerator.generateUnique().rawValue),
            forHTTPHeaderField: DDHTTPHeadersWriter.Constants.traceIDField
        )
        mutableRequest.setValue(
            String(tracingFeature.tracingUUIDGenerator.generateUnique().rawValue),
            forHTTPHeaderField: DDHTTPHeadersWriter.Constants.parentSpanIDField
        )

        return mutableRequest
    }

    func notifyStart(of task: URLSessionTask) {
        guard let ddTracer = Global.sharedTracer as? DDTracer else {
            return
        }
        guard
            let traceIDString = task.originalRequest?.value(forHTTPHeaderField: DDHTTPHeadersWriter.Constants.traceIDField),
            let spanIDString = task.originalRequest?.value(forHTTPHeaderField: DDHTTPHeadersWriter.Constants.parentSpanIDField) else {
                return
        }
        guard
            let traceIDRaw = UInt64(traceIDString),
            let spanIDRaw = UInt64(spanIDString) else {
                return
        }
        let spanContext = DDSpanContext(
            traceID: TracingUUID(rawValue: traceIDRaw),
            spanID: TracingUUID(rawValue: spanIDRaw),
            parentSpanID: nil
        )
        task.span = DDSpan(
            tracer: ddTracer,
            context: spanContext,
            operationName: "request",
            startTime: tracingFeature.dateProvider.currentDate(),
            tags: [:]
        )
    }

    func intercept(response: URLResponse?, of task: URLSessionTask?) -> URLResponse? {
        if let span = task?.span {
            span.finish()
        }
        return response
    }
}

/// Associates tracing information to given instance of `URLSessionTask` at runtime.
extension URLSessionTask {
    private static var spanAssociationKey: UInt8 = 0
    var span: DDSpan? {
        get { objc_getAssociatedObject(self, &Self.spanAssociationKey) as? DDSpan }
        set { objc_setAssociatedObject(self, &Self.spanAssociationKey, newValue, .OBJC_ASSOCIATION_RETAIN) }
    }
}
