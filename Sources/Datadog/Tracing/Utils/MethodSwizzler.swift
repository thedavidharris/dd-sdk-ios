/*
 * Unless explicitly stated otherwise all files in this repository are licensed under the Apache License Version 2.0.
 * This product includes software developed at Datadog (https://www.datadoghq.com/).
 * Copyright 2019-2020 Datadog, Inc.
 */

import Foundation

internal class MethodSwizzler {
    /// The `Method` controlled by this swizzler.
    let method: Method
    /// The original implementation of this `method`.
    let opaqueOriginalImplementation: IMP
    /// A new implementation of `method` installed by this swizzler.
    private(set) var opaqueNewImplementation: IMP?

    static func `for`(selector: Selector, inClass `class`: AnyClass) -> MethodSwizzler? {
        guard let method = findMethodRecursively(with: selector, in: `class`) else {
            return nil
        }
        let swizzler = MethodSwizzler(method: method)
        installedSwizzlers.append(swizzler)
        return swizzler
    }

    private init(method: Method) {
        self.method = method
        self.opaqueOriginalImplementation = method_getImplementation(method)
    }

    func originalImplementation<TypedIMP>() -> TypedIMP {
        return unsafeBitCast(opaqueOriginalImplementation, to: TypedIMP.self)
    }

    func currentImplementation<TypedIMP>() -> TypedIMP {
        return unsafeBitCast(method_getImplementation(method), to: TypedIMP.self)
    }

    func swizzle(to newIMP: IMP) {
        opaqueNewImplementation = newIMP
        method_setImplementation(method, newIMP)
    }

    func swizzleIfNotSwizzled(to newIMP: IMP) {
        if opaqueNewImplementation != nil {
            return
        }
        swizzle(to: newIMP)
    }
}

/// A collection of all installed `MethodSwizzlers` to unswizzle them in unit tests.
internal var installedSwizzlers: [MethodSwizzler] = []

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
