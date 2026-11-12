#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, TAStoreWriterState) {
    TAStoreWriterStateWriter = 0,   /* this process holds writer.lock */
    TAStoreWriterStateRefused = 1,  /* a live writer holds the lock; this process never writes samples */
};

/* SampleStore — the analytics store's single writer, mirroring the
 * executable reference in Distro files/36 §3 (academy_store.py, S1–S5):
 *
 *   S1 SINGLE WRITER. writer.lock is created O_EXCL with {pid, heartbeat}.
 *      A second writer is REFUSED — never queued, never merged. A lock
 *      whose heartbeat is older than 120 s and whose pid is dead may be
 *      reclaimed; the reclaim is counted in the manifest.
 *   S2 APPEND-ONLY SEGMENTS. samples-<UTC>.jsonl under
 *      ~/Library/Application Support/com.detroitautomationacademy.analytics/samples/
 *      Only the active segment is ever appended, only by the lock holder.
 *   S3 ROTATION + RETENTION. Rotate at 8 MiB or the UTC hour roll.
 *      Retention deletes oldest sealed segments first past 256 MiB total
 *      or 7 days of age; the active segment is never deleted.
 *   S4 INTEGRITY. manifest.json (single writer) carries per-segment
 *      {name, bytes, lines, sha256, sealed}; sealing hashes the segment.
 *   S5 CRASH DISCIPLINE. Appends are fsync'd per batch; a crash loses at
 *      most the tail of the active segment, which the manifest exposes.
 *
 * Nothing in this class touches the network; there is no network code
 * in the app. */
@interface SampleStore : NSObject
@property (nonatomic, readonly, copy) NSString *analyticsDirectoryPath;
@property (nonatomic, readonly, copy) NSString *samplesDirectoryPath;
@property (nonatomic, readonly) TAStoreWriterState writerState;
@property (nonatomic, readonly) BOOL lockWasReclaimed;
@property (nonatomic, readonly) unsigned long long totalBytes;
@property (nonatomic, readonly) NSUInteger segmentCount;
- (instancetype)initWithAnalyticsDirectory:(NSString *)analyticsDirectory;
- (BOOL)appendLines:(NSArray<NSString *> *)jsonLines;
- (void)heartbeatNow;
- (BOOL)deleteAllSamples;
- (void)sealAndClose;
@end

NS_ASSUME_NONNULL_END
