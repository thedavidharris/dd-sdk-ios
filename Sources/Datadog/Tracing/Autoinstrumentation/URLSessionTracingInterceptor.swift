/*
 * Unless explicitly stated otherwise all files in this repository are licensed under the Apache License Version 2.0.
 * This product includes software developed at Datadog (https://www.datadoghq.com/).
 * Copyright 2019-2020 Datadog, Inc.
 */

import Foundation

internal struct DebugURLSessionInterceptor: URLSessionInterceptor {
    func shouldIntercept(url: URL) -> Bool {
        return true
    }

    func shouldIntercept(request: URLRequest) -> Bool {
        return true
    }

    func intercept(request: URLRequest) -> URLRequest {
        print("Intercepting request: \(request)")
        return request
    }

    func notifyStart(of task: URLSessionTask) {
        print("Starting task: \(task)")
    }

    func intercept(response: URLResponse?, of task: URLSessionTask?) -> URLResponse? {
        print("Intercepting response: \(String(describing: response))")
        return response
    }
}
