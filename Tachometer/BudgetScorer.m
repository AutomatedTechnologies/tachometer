#import "BudgetScorer.h"

#include <fcntl.h>
#include <unistd.h>

@interface BudgetScorer ()
@property (nonatomic, copy) NSString *analyticsDir;
@property (nonatomic, copy) NSString *samplesDir;
@end

@implementation BudgetScorer

- (instancetype)initWithAnalyticsDirectory:(NSString *)analyticsDirectory
                        samplesDirectory:(NSString *)samplesDirectory {
    self = [super init];
    if (self) {
        _analyticsDir = [analyticsDirectory copy];
        _samplesDir = [samplesDirectory copy];
    }
    return self;
}

- (NSString *)verdictsFilePath {
    return [self.analyticsDir stringByAppendingPathComponent:@"verdicts.json"];
}

- (NSArray<NSDictionary *> *)loadBudgets {
    NSString *path = [[NSBundle mainBundle] pathForResource:@"budgets-v1" ofType:@"json"];
    NSData *data = path != nil ? [NSData dataWithContentsOfFile:path] : nil;
    NSDictionary *table = data != nil
        ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (![table isKindOfClass:[NSDictionary class]]
            || ![table[@"budgets"] isKindOfClass:[NSArray class]]) {
        return @[];
    }
    return table[@"budgets"];
}

/* Read-only, manifest-mediated, rotation-tolerant: segments listed in
 * the manifest are read in order; a line that does not parse (a torn
 * tail on the active segment) is skipped, never merged or fatal. */
- (NSArray<NSDictionary *> *)loadRecords {
    NSString *manifestPath = [self.samplesDir stringByAppendingPathComponent:@"manifest.json"];
    NSData *mdata = [NSData dataWithContentsOfFile:manifestPath];
    NSDictionary *manifest = mdata != nil
        ? [NSJSONSerialization JSONObjectWithData:mdata options:0 error:nil] : nil;
    NSMutableArray<NSDictionary *> *records = [NSMutableArray array];
    if (![manifest isKindOfClass:[NSDictionary class]]) {
        return records;
    }
    for (NSDictionary *seg in manifest[@"segments"]) {
        NSString *path = [self.samplesDir stringByAppendingPathComponent:seg[@"name"]];
        NSData *data = [NSData dataWithContentsOfFile:path];
        if (data == nil) {
            continue;
        }
        NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        for (NSString *line in [text componentsSeparatedByCharactersInSet:
                                [NSCharacterSet newlineCharacterSet]]) {
            if (line.length == 0) {
                continue;
            }
            NSDictionary *record = [NSJSONSerialization
                JSONObjectWithData:[line dataUsingEncoding:NSUTF8StringEncoding]
                           options:0 error:nil];
            if ([record isKindOfClass:[NSDictionary class]]) {
                [records addObject:record];
            }
        }
    }
    return records;
}

- (NSArray<NSDictionary *> *)scoreNow {
    NSArray<NSDictionary *> *budgets = [self loadBudgets];
    NSArray<NSDictionary *> *records = [self loadRecords];
    NSMutableArray<NSDictionary *> *verdicts = [NSMutableArray array];

    for (NSDictionary *budget in budgets) {
        NSString *app = budget[@"app"];
        NSArray *procs = [budget[@"procs"] isKindOfClass:[NSArray class]]
            ? budget[@"procs"] : nil; /* null procs = whole complex */
        NSMutableDictionary<NSNumber *, NSNumber *> *cpuByTs = [NSMutableDictionary dictionary];
        NSMutableDictionary<NSNumber *, NSNumber *> *rssByTs = [NSMutableDictionary dictionary];
        BOOL any = NO;
        for (NSDictionary *record in records) {
            if (![record[@"app"] isEqualToString:app]) {
                continue;
            }
            if (procs != nil && ![procs containsObject:record[@"proc"]]) {
                continue;
            }
            any = YES;
            NSNumber *ts = @([record[@"ts"] doubleValue]);
            cpuByTs[ts] = @([cpuByTs[ts] doubleValue]
                            + [record[@"cpu_pct_thread"] doubleValue]);
            rssByTs[ts] = @([rssByTs[ts] unsignedLongLongValue]
                            + [record[@"rss_bytes"] unsignedLongLongValue]);
        }
        if (!any) {
            [verdicts addObject:@{ @"id": budget[@"id"], @"verdict": @"NO DATA" }];
            continue;
        }
        double cpuSum = 0.0, cpuPeak = 0.0;
        for (NSNumber *ts in cpuByTs) {
            double v = [cpuByTs[ts] doubleValue];
            cpuSum += v;
            cpuPeak = MAX(cpuPeak, v);
        }
        double cpuSustained = cpuSum / (double)cpuByTs.count;
        unsigned long long rssPeak = 0;
        for (NSNumber *ts in rssByTs) {
            rssPeak = MAX(rssPeak, [rssByTs[ts] unsignedLongLongValue]);
        }
        NSMutableArray<NSString *> *breaches = [NSMutableArray array];
        if (budget[@"cpu_sustained_max"] != nil
                && ![budget[@"cpu_sustained_max"] isKindOfClass:[NSNull class]]
                && cpuSustained > [budget[@"cpu_sustained_max"] doubleValue]) {
            [breaches addObject:[NSString stringWithFormat:@"cpu_sustained %.1f > %@",
                                 cpuSustained, budget[@"cpu_sustained_max"]]];
        }
        if (budget[@"cpu_peak_max"] != nil
                && ![budget[@"cpu_peak_max"] isKindOfClass:[NSNull class]]
                && cpuPeak > [budget[@"cpu_peak_max"] doubleValue]) {
            [breaches addObject:[NSString stringWithFormat:@"cpu_peak %.1f > %@",
                                 cpuPeak, budget[@"cpu_peak_max"]]];
        }
        if (budget[@"rss_peak_max_bytes"] != nil
                && ![budget[@"rss_peak_max_bytes"] isKindOfClass:[NSNull class]]
                && rssPeak > [budget[@"rss_peak_max_bytes"] unsignedLongLongValue]) {
            [breaches addObject:[NSString stringWithFormat:@"rss_peak %llu > %@",
                                 rssPeak, budget[@"rss_peak_max_bytes"]]];
        }
        [verdicts addObject:@{
            @"id": budget[@"id"],
            @"verdict": breaches.count > 0 ? @"FAIL" : @"PASS",
            @"cpu_sustained": @((round(cpuSustained * 10.0) / 10.0)),
            @"cpu_peak": @((round(cpuPeak * 10.0) / 10.0)),
            @"rss_peak_bytes": @(rssPeak),
            @"breaches": breaches,
        }];
    }

    /* verdicts.json — written by the scorer alone (tmp, fsync, rename). */
    NSDictionary *file = @{
        @"format": @"academy-verdicts/1",
        @"scored_at": @([[NSDate date] timeIntervalSince1970]),
        @"source": @"Tachometer in-app scorer (files/36 §5 semantics)",
        @"verdicts": verdicts,
    };
    NSData *data = [NSJSONSerialization dataWithJSONObject:file
                                                   options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys
                                                     error:nil];
    if (data != nil) {
        NSString *tmp = [[self verdictsFilePath] stringByAppendingString:@".tmp"];
        [data writeToFile:tmp atomically:NO];
        int fd = open([tmp fileSystemRepresentation], O_WRONLY);
        if (fd >= 0) {
            fsync(fd);
            close(fd);
        }
        rename([tmp fileSystemRepresentation],
               [[self verdictsFilePath] fileSystemRepresentation]);
    }
    return verdicts;
}

@end
