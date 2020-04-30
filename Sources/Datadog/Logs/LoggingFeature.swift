/*
 * Unless explicitly stated otherwise all files in this repository are licensed under the Apache License Version 2.0.
 * This product includes software developed at Datadog (https://www.datadoghq.com/).
 * Copyright 2019-2020 Datadog, Inc.
 */

import Foundation

/// Obtains a subdirectory in `/Library/Caches` where log files are stored.
internal func obtainLoggingFeatureDirectory() throws -> Directory {
    return try Directory(withSubdirectoryPath: "com.datadoghq.logs/v1")
}

/// Creates and owns componetns enabling logging feature.
/// Bundles dependencies for other logging-related components created later at runtime  (i.e. `Logger`).
internal final class LoggingFeature {
    /// Single, shared instance of `LoggingFeature`.
    internal static var instance: LoggingFeature?

    // MARK: - Dependencies

    let appContext: AppContext
    let dateProvider: DateProvider
    let userInfoProvider: UserInfoProvider
    let networkConnectionInfoProvider: NetworkConnectionInfoProviderType
    let carrierInfoProvider: CarrierInfoProviderType

    // MARK: - Components

    /// Log files storage.
    let storage: Storage
    /// Logs upload worker.
    let upload: Upload

    /// Encapsulates  storage stack setup for `LoggingFeature`.
    class Storage {
        /// Writes logs to files.
        let writer: FileWriter
        /// Reads logs from files.
        let reader: FileReader

        /// NOTE: any change to logs data format requires updating the logs directory url to be unique
        static let dataFormat = DataFormat(prefix: "[", suffix: "]", separator: ",")

        init(
            directory: Directory,
            performance: PerformancePreset,
            dateProvider: DateProvider,
            readWriteQueue: DispatchQueue
        ) {
            let orchestrator = FilesOrchestrator(
                directory: directory,
                performance: performance,
                dateProvider: dateProvider
            )

            self.writer = FileWriter(dataFormat: Storage.dataFormat, orchestrator: orchestrator, queue: readWriteQueue)
            self.reader = FileReader(dataFormat: Storage.dataFormat, orchestrator: orchestrator, queue: readWriteQueue)
        }
    }

    /// Encapsulates upload stack setup for `LoggingFeature`.
    class Upload {
        /// Uploads logs to server.
        let uploader: DataUploadWorker

        init(
            storage: Storage,
            appContext: AppContext,
            performance: PerformancePreset,
            httpClient: HTTPClient,
            logsUploadURLProvider: UploadURLProvider,
            networkConnectionInfoProvider: NetworkConnectionInfoProviderType,
            uploadQueue: DispatchQueue
        ) {
            let httpHeaders: HTTPHeaders
            let uploadConditions: DataUploadConditions

            if let mobileDevice = appContext.mobileDevice { // mobile device
                httpHeaders = HTTPHeaders(
                    headers: [
                        .contentTypeHeader(contentType: .applicationJSON),
                        .userAgentHeader(for: mobileDevice, appName: appContext.executableName, appVersion: appContext.bundleVersion)
                    ]
                )
                uploadConditions = DataUploadConditions(
                    batteryStatus: BatteryStatusProvider(mobileDevice: mobileDevice),
                    networkConnectionInfo: networkConnectionInfoProvider
                )
            } else { // other device (i.e. iOS Simulator)
                httpHeaders = HTTPHeaders(
                    headers: [
                        .contentTypeHeader(contentType: .applicationJSON)
                        // UA http header will default to the one produced by the OS
                    ]
                )
                uploadConditions = DataUploadConditions(
                    batteryStatus: nil, // uploads do not depend on battery status
                    networkConnectionInfo: networkConnectionInfoProvider
                )
            }

            let dataUploader = DataUploader(
                urlProvider: logsUploadURLProvider,
                httpClient: httpClient,
                httpHeaders: httpHeaders
            )

            self.uploader = DataUploadWorker(
                queue: uploadQueue,
                fileReader: storage.reader,
                dataUploader: dataUploader,
                uploadConditions: uploadConditions,
                delay: DataUploadDelay(performance: performance),
                featureName: "logging"
            )
        }
    }

    // MARK: - Initialization

    init(
        directory: Directory,
        appContext: AppContext,
        performance: PerformancePreset,
        httpClient: HTTPClient,
        logsUploadURLProvider: UploadURLProvider,
        dateProvider: DateProvider,
        userInfoProvider: UserInfoProvider,
        networkConnectionInfoProvider: NetworkConnectionInfoProviderType,
        carrierInfoProvider: CarrierInfoProviderType
    ) {
        // Bundle dependencies
        self.appContext = appContext
        self.dateProvider = dateProvider
        self.userInfoProvider = userInfoProvider
        self.networkConnectionInfoProvider = networkConnectionInfoProvider
        self.carrierInfoProvider = carrierInfoProvider

        // Initialize components
        let readWriteQueue = DispatchQueue(
            label: "com.datadoghq.ios-sdk-logs-read-write",
            target: .global(qos: .utility)
        )
        self.storage = Storage(
            directory: directory,
            performance: performance,
            dateProvider: dateProvider,
            readWriteQueue: readWriteQueue
        )

        let uploadQueue = DispatchQueue(
            label: "com.datadoghq.ios-sdk-logs-upload",
            target: .global(qos: .utility)
        )
        self.upload = Upload(
            storage: self.storage,
            appContext: appContext,
            performance: performance,
            httpClient: httpClient,
            logsUploadURLProvider: logsUploadURLProvider,
            networkConnectionInfoProvider: networkConnectionInfoProvider,
            uploadQueue: uploadQueue
        )
    }
}
