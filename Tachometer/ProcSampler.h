#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/* One process in one sampling pass, attributed to its Academy app family. */
@interface TAProcessRow : NSObject
@property (nonatomic) pid_t pid;
@property (nonatomic, copy) NSString *appName;    /* the family root app's name */
@property (nonatomic, copy) NSString *bundleId;   /* the family root bundle id */
@property (nonatomic, copy) NSString *role;       /* contract proc label (files/36 §3): shell / renderer / gpu / helper / app name */
@property (nonatomic, copy) NSString *exeName;
@property (nonatomic) double pctOneThread;        /* 100% = one hardware thread */
@property (nonatomic) double pctTotal;            /* share of ALL hardware threads */
@property (nonatomic) uint64_t rssBytes;          /* resident size at this pass (pti_resident_size) */
@property (nonatomic) BOOL isRoot;                /* the family root process */
@property (nonatomic) BOOL isSelf;                /* Tachometer's own rows */
@end

/* ProcSampler — enumerates processes via libproc (proc_listpids +
 * proc_pidinfo), reads cumulative CPU counters (PROC_PIDTASKINFO),
 * attributes every process to an Academy app family, and converts counter
 * deltas to rates through CPUMath. Unprivileged: it reads only what macOS
 * exposes for the owner's own processes, and skips anything it cannot
 * read rather than guessing. No network code exists in this class. */
@interface ProcSampler : NSObject
@property (nonatomic, readonly) int logicalThreads;
- (NSArray<TAProcessRow *> *)sample;
@end

NS_ASSUME_NONNULL_END
