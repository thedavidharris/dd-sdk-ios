/*
 * Unless explicitly stated otherwise all files in this repository are licensed under the Apache License Version 2.0.
 * This product includes software developed at Datadog (https://www.datadoghq.com/).
 * Copyright 2019-2020 Datadog, Inc.
 */

import Foundation

internal struct MethodSwizzlerException: Error {
    let description: String
}

private class RuntimeLock {}
private let runtimeLock = RuntimeLock()

internal class MethodSwizzler<OriginalSignature, SwizzledSignature> {
    /// A source reference to swizled method: Class + selector.
    let source: (class: AnyClass, selector: Selector)
    /// The runtime `Method` swizzled by this `MethodSwizzler`.
    let method: Method

    init(selector: Selector, inClass `class`: AnyClass) throws {
        guard let method = findMethodRecursively(with: selector, in: `class`) else {
            throw MethodSwizzlerException(description: "Selector \(selector) not found for class: \(`class`)")
        }
        self.source = (class: `class`, selector: selector)
        self.method = method

        objc_sync_enter(runtimeLock)
        self.originalImplementationPointer = method_getImplementation(method)
        self.originalImplementation = unsafeBitCast(originalImplementationPointer, to: OriginalSignature.self)
        objc_sync_exit(runtimeLock)
    }

    // MARK: - Original implementation

    let originalImplementationPointer: IMP
    let originalImplementation: OriginalSignature

    // MARK: - Swizzled implementation
    func setNewImplementation(_ newImplementation: SwizzledSignature) {
        objc_sync_enter(runtimeLock)
        defer { objc_sync_exit(runtimeLock) }

        let newImplementationBlock = imp_implementationWithBlock(newImplementation)
        method_setImplementation(method, newImplementationBlock)
    }
}

// MARK: - Reflection helpers

private func findMethodRecursively(with selector: Selector, in klass: AnyClass) -> Method? {
    var headKlass: AnyClass? = klass
    while let someKlass = headKlass {
        if let method = findMethod(with: selector, in: someKlass) {
            return method
        }
        headKlass = class_getSuperclass(headKlass)
    }
    return nil
}

private func findMethod(with selector: Selector, in klass: AnyClass) -> Method? {
    var methodsCount: UInt32 = 0
    let methodsCountPtr = withUnsafeMutablePointer(to: &methodsCount) { $0 }
    guard let methods: UnsafeMutablePointer<Method> = class_copyMethodList(klass, methodsCountPtr) else {
        return nil
    }
    defer {
        free(methods)
    }
    for index in 0..<Int(methodsCount) {
        let method = methods.advanced(by: index).pointee
        if method_getName(method) == selector {
            return method
        }
    }
    return nil
}
