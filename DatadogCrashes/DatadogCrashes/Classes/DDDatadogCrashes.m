//
//  DDDatadogCrashes.m
//  DatadogCrashes
//
//  Created by Maciek Grzybowski on 11/03/2020.
//

#import "DDDatadogCrashes.h"
@import DatadogObjc;
#import <CrashReporter/CrashReporter.h>

@implementation DDDatadogCrashes
static PLCrashReporter *reporter;
static DDLogger *logger;

+ (void)enable {
    DDLoggerBuilder *builder = [DDLogger builder];
    [builder setWithLoggerName: @"crash-reporter"];
    [builder setWithServiceName: [NSBundle mainBundle].bundleIdentifier];

    logger = [builder build];

    [self setUpCrashReporting];
}

+ (void)setUpCrashReporting {
    PLCrashReporterConfig *config = [PLCrashReporterConfig defaultConfiguration];
    reporter = [[PLCrashReporter alloc] initWithConfiguration: config];

    if ([reporter hasPendingCrashReport]) {
        [self handleCrashReport];
    }

    [reporter enableCrashReporter];
}

+ (void)handleCrashReport {
    NSData *crashData = [reporter loadPendingCrashReportData];
    [reporter purgePendingCrashReport];

    PLCrashReport *crashReport = [[PLCrashReport alloc] initWithData:crashData error:nil];

    NSString *crashlog = [PLCrashReportTextFormatter stringValueForCrashReport:crashReport withTextFormat:PLCrashReportTextFormatiOS];

    [logger critical: crashlog];
}

@end
