/*
 * Unless explicitly stated otherwise all files in this repository are licensed under the Apache License Version 2.0.
 * This product includes software developed at Datadog (https://www.datadoghq.com/).
 * Copyright 2019-2020 Datadog, Inc.
 */

import Foundation
import UIKit

public class UIViewControllerSwizzler {
    /// Swizzles the `UIViewController.viewDidLoad()`
    class ViewDidLoad: MethodSwizzler<
        @convention(c) (UIViewController, Selector) -> Void, // <- Swizzle from
        @convention(block) (UIViewController) -> Void        // <- Swizzle to
    > {
        init() throws {
            try super.init(selector: #selector(UIViewController.viewDidLoad), inClass: UIViewController.self)
        }
    }

    /// Swizzles the `UIViewController.viewWillAppear()`
    class ViewWillAppear: MethodSwizzler<
        @convention(c) (UIViewController, Selector, Bool) -> Void, // <- Swizzle from
        @convention(block) (UIViewController, Bool) -> Void        // <- Swizzle to
    > {
        init() throws {
            try super.init(selector: #selector(UIViewController.viewWillAppear(_:)), inClass: UIViewController.self)
        }
    }

    /// Swizzles the `UIViewController.viewDidAppear()`
    class ViewDidAppear: MethodSwizzler<
        @convention(c) (UIViewController, Selector, Bool) -> Void, // <- Swizzle from
        @convention(block) (UIViewController, Bool) -> Void        // <- Swizzle to
    > {
        init() throws {
            try super.init(selector: #selector(UIViewController.viewDidAppear), inClass: UIViewController.self)
        }
    }

    public init() throws {
        let viewDidLoad = try ViewDidLoad() // instantiate swizzler
        viewDidLoad.setNewImplementation { `self` in // set new implementation
            print("viewDidLoad() was called")
            viewDidLoad.originalImplementation(`self`, viewDidLoad.source.selector) // call super.viewDidLoad()
        }

        let viewWillAppear = try ViewWillAppear() // instantiate swizzler
        viewWillAppear.setNewImplementation { `self`, animated in // set new implementation
            print("viewWillAppear(\(animated)) was called")
            viewWillAppear.originalImplementation(`self`, viewWillAppear.source.selector, animated) // call super.viewDidLoad()
        }

        let viewDidAppear = try ViewDidAppear() // instantiate swizzler
        viewDidAppear.setNewImplementation { `self`, animated in // set new implementation
            print("viewDidAppear(\(animated)) was called")
            viewDidAppear.originalImplementation(`self`, viewDidAppear.source.selector, animated) // call super.viewDidLoad()
        }
    }
}
