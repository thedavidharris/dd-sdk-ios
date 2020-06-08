/*
 * Unless explicitly stated otherwise all files in this repository are licensed under the Apache License Version 2.0.
 * This product includes software developed at Datadog (https://www.datadoghq.com/).
 * Copyright 2019-2020 Datadog, Inc.
 */

import XCTest
@testable import Datadog

@objcMembers
private class Superclass: NSObject {
    var _methodWithNoReturnValueCalledInSuperclass = false
    func methodWithNoReturnValue() {
        _methodWithNoReturnValueCalledInSuperclass = true
    }

    func methodReturningValue() -> String {
        return "superclass"
    }
}

private class Subclass: Superclass {
    var _methodWithNoReturnValueCalledInSubclass = false
    override func methodWithNoReturnValue() {
        _methodWithNoReturnValueCalledInSubclass = true
        super.methodWithNoReturnValue()
    }

    override func methodReturningValue() -> String {
        return super.methodReturningValue() + ".subclass"
    }

    func uniqueMethodOnSubclass() {}
}

extension MethodSwizzler {
    func unswizzle() { method_setImplementation(method, originalImplementationPointer) }
}

class MethodSwizzlerTests: XCTestCase {
    // MARK: - Swizzling method with no return value

    func testGivenSuperclass_itSwizzlesMethodWithNoReturnValue() throws {
        // Given
        class SuperclassSwizzling: MethodSwizzler<
            /// Swizzle from:
            @convention(c) (Superclass, Selector) -> Void,
            /// to:
            @convention(block) (Superclass) -> Void
        > {
            init() throws {
                try super.init(selector: #selector(Superclass.methodWithNoReturnValue), inClass: Superclass.self)
            }
        }
        var swizzledImplementationWasCalled = false

        // When
        let swizzling = try SuperclassSwizzling()
        swizzling.setNewImplementation { `self` in
            swizzledImplementationWasCalled = true
            swizzling.originalImplementation(`self`, swizzling.source.selector)
        }

        // Then
        let instance = Superclass()
        instance.perform(swizzling.source.selector)
        XCTAssertTrue(instance._methodWithNoReturnValueCalledInSuperclass)
        XCTAssertTrue(swizzledImplementationWasCalled)

        swizzling.unswizzle()
    }

    func testGivenSubclass_itSwizzlesMethodWithNoReturnValue() throws {
        // Given
        class SubclassSwizzling: MethodSwizzler<
            /// Swizzle from:
            @convention(c) (Subclass, Selector) -> Void,
            /// to:
            @convention(block) (Subclass) -> Void
        > {
            init() throws {
                try super.init(selector: #selector(Subclass.methodWithNoReturnValue), inClass: Subclass.self)
            }
        }
        var swizzledImplementationWasCalled = false

        // When
        let swizzling = try SubclassSwizzling()
        swizzling.setNewImplementation { `self` in
            swizzledImplementationWasCalled = true
            swizzling.originalImplementation(`self`, swizzling.source.selector)
        }

        // Then
        let instance = Subclass()
        instance.perform(swizzling.source.selector)
        XCTAssertTrue(instance._methodWithNoReturnValueCalledInSubclass)
        XCTAssertTrue(instance._methodWithNoReturnValueCalledInSuperclass)
        XCTAssertTrue(swizzledImplementationWasCalled)

        swizzling.unswizzle()
    }

    // MARK: - Swizzling method with a return value

    func testGivenSuperclass_itSwizzlesMethodWithReturnValue() throws {
        // Given
        class SuperclassSwizzling: MethodSwizzler<
            /// Swizzle from:
            @convention(c) (Superclass, Selector) -> String,
            /// to:
            @convention(block) (Superclass) -> String
        > {
            init() throws {
                try super.init(
                    selector: #selector(Superclass.methodReturningValue as (Superclass) -> () -> String),
                    inClass: Superclass.self
                )
            }
        }

        // When
        let swizzling = try SuperclassSwizzling()
        swizzling.setNewImplementation { `self` in
            let originalReturnValue = swizzling.originalImplementation(`self`, swizzling.source.selector)
            return originalReturnValue + ".swizzled"
        }

        // Then
        let instance = Superclass()
        let returnValue = instance.perform(swizzling.source.selector)?.takeUnretainedValue() as? String
        XCTAssertEqual(returnValue, "superclass.swizzled")

        swizzling.unswizzle()
    }

    func testGivenSubclass_itSwizzlesMethodWithReturnValue() throws {
        // Given
        class SubclassSwizzling: MethodSwizzler<
            /// Swizzle from:
            @convention(c) (Subclass, Selector) -> String,
            /// to:
            @convention(block) (Subclass) -> String
        > {
            init() throws {
                try super.init(
                    selector: #selector(Subclass.methodReturningValue as (Subclass) -> () -> String),
                    inClass: Subclass.self
                )
            }
        }

        // When
        let swizzling = try SubclassSwizzling()
        swizzling.setNewImplementation { `self` in
            let originalReturnValue = swizzling.originalImplementation(`self`, swizzling.source.selector)
            return originalReturnValue + ".swizzled"
        }

        // Then
        let instance = Subclass()
        let returnValue = instance.perform(swizzling.source.selector)?.takeUnretainedValue() as? String
        XCTAssertEqual(returnValue, "superclass.subclass.swizzled")

        swizzling.unswizzle()
    }

    // MARK: - 3rd party swizzling

    func testGivenAlreadySwizzledMethod_itSwizzlesItAgain() throws {
        // Given
        class SubclassSwizzling: MethodSwizzler<
            /// Swizzle from:
            @convention(c) (Subclass, Selector) -> String,
            /// to:
            @convention(block) (Subclass) -> String
        > {
            init() throws {
                try super.init(
                    selector: #selector(Subclass.methodReturningValue as (Subclass) -> () -> String),
                    inClass: Subclass.self
                )
            }
        }
        let swizzling1 = try SubclassSwizzling()
        swizzling1.setNewImplementation { `self` in
            let originalReturnValue = swizzling1.originalImplementation(`self`, swizzling1.source.selector)
            return originalReturnValue + ".swizzled1"
        }

        // When
        let swizzling2 = try SubclassSwizzling()
        swizzling2.setNewImplementation { `self` in
            let originalReturnValue = swizzling2.originalImplementation(`self`, swizzling2.source.selector)
            return originalReturnValue + ".swizzled2"
        }

        // Then
        let instance = Subclass()
        let returnValue = instance.perform(swizzling2.source.selector)?.takeUnretainedValue() as? String
        XCTAssertEqual(returnValue, "superclass.subclass.swizzled1.swizzled2")

        swizzling1.unswizzle() // this sets the original implementation, removing also the effect of `swizzling2`
    }

    // MARK: - Errors

    func testWhenSelectorCannotBeFound_itThrows() {
        // Given
        class SubclassSwizzling: MethodSwizzler<
            /// Swizzle from:
            @convention(c) (Subclass, Selector) -> Void,
            /// to:
            @convention(block) (Subclass) -> Void
        > {
            init() throws {
                try super.init(
                    selector: #selector(Subclass.uniqueMethodOnSubclass as (Subclass) -> () -> Void),
                    inClass: Superclass.self // the `.uniqueMethodOnSubclass()` doesn't exist on `Superclass`
                )
            }
        }

        XCTAssertThrowsError(try SubclassSwizzling())
    }
}
