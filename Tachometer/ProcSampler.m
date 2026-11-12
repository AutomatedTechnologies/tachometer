#import "ProcSampler.h"
#import "CPUMath.h"

#import <AppKit/AppKit.h>
#include <libproc.h>
#include <mach/mach_time.h>
#include <sys/sysctl.h>
#include <time.h>

@implementation TAProcessRow
@end

@interface ProcSampler ()
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSArray<NSNumber *> *> *previous;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *bundleIdByAppPath;
@property (nonatomic) int cachedThreads;
@end

@implementation ProcSampler

- (instancetype)init {
    self = [super init];
    if (self) {
        _previous = [NSMutableDictionary dictionary];
        _bundleIdByAppPath = [NSMutableDictionary dictionary];
        int threads = 0;
        size_t size = sizeof(threads);
        if (sysctlbyname("hw.ncpu", &threads, &size, NULL, 0) != 0 || threads < 1) {
            threads = 1;
        }
        _cachedThreads = threads;
    }
    return self;
}

- (int)logicalThreads {
    return self.cachedThreads;
}

/* Mach absolute time (the units of pti_total_user / pti_total_system)
 * converted to nanoseconds with the kernel's own timebase. */
+ (uint64_t)ticksToNanoseconds:(uint64_t)ticks {
    static mach_timebase_info_data_t timebase;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        mach_timebase_info(&timebase);
        if (timebase.denom == 0) {
            timebase.numer = 1;
            timebase.denom = 1;
        }
    });
    return (uint64_t)((ticks * timebase.numer) / timebase.denom);
}

+ (uint64_t)wallNanoseconds {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ULL + (uint64_t)ts.tv_nsec;
}

/* Contract role labels (files/36 §3). Non-root processes map from the
 * executable name: Electron helpers carry their role in the name
 * ("<App> Helper (GPU)", "<App> Helper (Renderer)"); any other child of
 * a complex is a "helper". Roots are labeled by the caller after family
 * grouping: "shell" for a multi-process complex, the app's own name for
 * a single-process native app. */
+ (NSString *)roleForExeName:(NSString *)exeName isRoot:(BOOL)isRoot {
    if (isRoot) {
        return @"shell"; /* provisional; single-process roots renamed by caller */
    }
    if ([exeName rangeOfString:@"GPU"].location != NSNotFound) {
        return @"gpu";
    }
    if ([exeName rangeOfString:@"Renderer"].location != NSNotFound) {
        return @"renderer";
    }
    return @"helper";
}

/* Fallback attribution for processes whose root is not an NSWorkspace
 * application: parse "<something>.app/Contents/..." out of the executable
 * path and read that bundle's identifier (cached per bundle path). */
- (NSString *)bundleIdForExecutablePath:(NSString *)path {
    NSRange marker = [path rangeOfString:@".app/Contents/"];
    if (marker.location == NSNotFound) {
        return nil;
    }
    NSString *appPath = [path substringToIndex:marker.location + 4]; /* include ".app" */
    NSString *cached = self.bundleIdByAppPath[appPath];
    if (cached != nil) {
        return cached.length > 0 ? cached : nil;
    }
    NSString *bundleId = [[NSBundle bundleWithPath:appPath] bundleIdentifier];
    self.bundleIdByAppPath[appPath] = bundleId != nil ? bundleId : @"";
    return bundleId;
}

- (NSArray<TAProcessRow *> *)sample {
    uint64_t wallNow = [[self class] wallNanoseconds];

    /* Roots: the GUI applications NSWorkspace knows, by pid. */
    NSMutableDictionary<NSNumber *, NSRunningApplication *> *roots =
        [NSMutableDictionary dictionary];
    for (NSRunningApplication *app in [[NSWorkspace sharedWorkspace] runningApplications]) {
        if (app.bundleIdentifier != nil) {
            roots[@(app.processIdentifier)] = app;
        }
    }

    /* Full process table for this pass: pid -> ppid / start / cpu / path. */
    int byteSize = proc_listpids(PROC_ALL_PIDS, 0, NULL, 0);
    if (byteSize <= 0) {
        return @[];
    }
    NSMutableData *pidData = [NSMutableData dataWithLength:(NSUInteger)byteSize];
    int filled = proc_listpids(PROC_ALL_PIDS, 0, [pidData mutableBytes], byteSize);
    if (filled <= 0) {
        return @[];
    }
    int pidCount = filled / (int)sizeof(int);
    const int *pids = (const int *)[pidData bytes];

    NSMutableDictionary<NSNumber *, NSNumber *> *parentByPid = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSNumber *, NSArray<NSNumber *> *> *readingByPid =
        [NSMutableDictionary dictionary];
    NSMutableDictionary<NSNumber *, NSString *> *pathByPid = [NSMutableDictionary dictionary];
    for (int i = 0; i < pidCount; i++) {
        pid_t pid = pids[i];
        if (pid <= 0) {
            continue;
        }
        struct proc_taskinfo taskInfo;
        if (proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &taskInfo, PROC_PIDTASKINFO_SIZE)
                != PROC_PIDTASKINFO_SIZE) {
            continue; /* not readable (another user's, or already gone) — skip, never guess */
        }
        struct proc_bsdinfo bsdInfo;
        if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsdInfo, PROC_PIDTBSDINFO_SIZE)
                != PROC_PIDTBSDINFO_SIZE) {
            continue;
        }
        char pathBuffer[MAXPATHLEN];
        int pathLength = proc_pidpath(pid, pathBuffer, sizeof(pathBuffer));
        NSString *path = pathLength > 0
            ? [NSString stringWithUTF8String:pathBuffer] : @"";
        uint64_t cpuTicks = taskInfo.pti_total_user + taskInfo.pti_total_system;
        uint64_t cpuNs = [[self class] ticksToNanoseconds:cpuTicks];
        parentByPid[@(pid)] = @(bsdInfo.pbi_ppid);
        readingByPid[@(pid)] = @[ @(cpuNs), @(bsdInfo.pbi_start_tvsec),
                                  @(taskInfo.pti_resident_size) ];
        pathByPid[@(pid)] = path;
    }

    pid_t selfPid = [[NSProcessInfo processInfo] processIdentifier];
    NSMutableArray<TAProcessRow *> *rows = [NSMutableArray array];
    NSMutableDictionary<NSString *, NSArray<NSNumber *> *> *nextPrevious =
        [NSMutableDictionary dictionary];

    for (NSNumber *pidNumber in [readingByPid allKeys]) {
        pid_t pid = (pid_t)[pidNumber intValue];
        NSArray<NSNumber *> *reading = readingByPid[pidNumber];
        uint64_t cpuNs = [reading[0] unsignedLongLongValue];
        uint64_t startSec = [reading[1] unsignedLongLongValue];

        /* Attribute to a family root: walk the parent chain to an
         * NSWorkspace application; fall back to the .app path parse. */
        NSString *rootBundleId = nil;
        NSString *rootName = nil;
        pid_t rootPid = -1;
        pid_t cursor = pid;
        for (int hops = 0; hops < 32; hops++) {
            NSRunningApplication *root = roots[@(cursor)];
            if (root != nil) {
                rootBundleId = root.bundleIdentifier;
                rootName = root.localizedName;
                rootPid = cursor;
                break;
            }
            NSNumber *parent = parentByPid[@(cursor)];
            if (parent == nil || [parent intValue] <= 0
                    || [parent intValue] == cursor) {
                break;
            }
            cursor = (pid_t)[parent intValue];
        }
        if (rootBundleId == nil) {
            rootBundleId = [self bundleIdForExecutablePath:pathByPid[pidNumber] ?: @""];
            if (rootBundleId != nil) {
                rootName = [[rootBundleId componentsSeparatedByString:@"."] lastObject];
                rootPid = pid; /* self-rooted via its own bundle path */
            }
        }
        if (rootBundleId == nil
                || ![rootBundleId hasPrefix:@"com.detroitautomationacademy."]) {
            continue; /* Academy families only — the owner's own estate */
        }

        /* Delta against the previous pass, keyed by pid + start time so a
         * reused pid can never inherit a dead process's counters. */
        NSString *key = [NSString stringWithFormat:@"%d:%llu", pid,
                         (unsigned long long)startSec];
        double pctOne = 0.0;
        double pctTotal = 0.0;
        NSArray<NSNumber *> *prev = self.previous[key];
        if (prev != nil) {
            TACpuPercent rate = ta_cpu_percent([prev[0] unsignedLongLongValue], cpuNs,
                                               [prev[1] unsignedLongLongValue], wallNow,
                                               self.cachedThreads);
            if (rate.valid) {
                pctOne = rate.pct_one_thread;
                pctTotal = rate.pct_total_hardware;
            }
        }
        nextPrevious[key] = @[ @(cpuNs), @(wallNow) ];

        NSString *exeName = [pathByPid[pidNumber] lastPathComponent] ?: @"";
        TAProcessRow *row = [[TAProcessRow alloc] init];
        row.pid = pid;
        row.appName = rootName != nil ? rootName : rootBundleId;
        row.bundleId = rootBundleId;
        row.exeName = exeName;
        row.isRoot = (pid == rootPid);
        row.role = [[self class] roleForExeName:exeName isRoot:row.isRoot];
        row.pctOneThread = pctOne;
        row.pctTotal = pctTotal;
        row.rssBytes = [reading[2] unsignedLongLongValue];
        row.isSelf = (pid == selfPid);
        [rows addObject:row];
    }
    self.previous = nextPrevious;

    /* Root role resolution (files/36 §3): a multi-process complex's root
     * is its "shell"; a single-process native app's root carries the
     * app's own name. Decided only once family sizes are known. */
    NSMutableDictionary<NSString *, NSNumber *> *familySizes = [NSMutableDictionary dictionary];
    for (TAProcessRow *row in rows) {
        familySizes[row.bundleId] = @([familySizes[row.bundleId] integerValue] + 1);
    }
    for (TAProcessRow *row in rows) {
        if (row.isRoot && [familySizes[row.bundleId] integerValue] <= 1) {
            row.role = row.appName;
        }
    }

    [rows sortUsingComparator:^NSComparisonResult(TAProcessRow *a, TAProcessRow *b) {
        NSComparisonResult byApp = [a.appName compare:b.appName];
        if (byApp != NSOrderedSame) {
            return byApp;
        }
        if (a.pctTotal != b.pctTotal) {
            return a.pctTotal > b.pctTotal ? NSOrderedAscending : NSOrderedDescending;
        }
        return a.pid < b.pid ? NSOrderedAscending : NSOrderedDescending;
    }];
    return rows;
}

@end
