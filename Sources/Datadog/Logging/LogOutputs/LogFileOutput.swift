/*
 * Unless explicitly stated otherwise all files in this repository are licensed under the Apache License Version 2.0.
 * This product includes software developed at Datadog (https://www.datadoghq.com/).
 * Copyright 2019-2020 Datadog, Inc.
 */

import Foundation

/// `LogOutput` which saves logs to file.
internal struct LogFileOutput: LogOutput {
    let logBuilder: LogBuilder
    let fileWriter: Writer
    /// Integration with RUM Errors.
    let rumErrorsIntegration: LoggingWithRUMErrorsIntegration?

    func writeLogWith(level: LogLevel, message: String, error: DDError?, date: Date, attributes: LogAttributes, tags: Set<String>) {
        let log = logBuilder.createLogWith(level: level, message: message, error: error, date: date, attributes: attributes, tags: tags)
        fileWriter.write(value: log)

        if level.rawValue >= LogLevel.error.rawValue {
            rumErrorsIntegration?.addError(for: log)
        }
    }
}
