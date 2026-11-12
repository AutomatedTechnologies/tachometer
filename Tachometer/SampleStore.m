#import "SampleStore.h"

#import <CommonCrypto/CommonDigest.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <unistd.h>

static const unsigned long long kRotateBytes = 8ULL * 1024ULL * 1024ULL;
static const unsigned long long kRetainBytes = 256ULL * 1024ULL * 1024ULL;
static const NSTimeInterval kRetainSeconds = 7.0 * 24.0 * 60.0 * 60.0;
static const NSTimeInterval kStaleAfterSeconds = 120.0;

@interface SampleStore ()
@property (nonatomic, copy) NSString *analyticsDir;
@property (nonatomic, copy) NSString *samplesDir;
@property (nonatomic) TAStoreWriterState state;
@property (nonatomic) BOOL reclaimed;
@property (nonatomic, strong) NSMutableDictionary *manifest;
@property (nonatomic, strong, nullable) NSFileHandle *activeHandle;
@property (nonatomic, copy, nullable) NSString *activeName;
@property (nonatomic, copy, nullable) NSString *activeHour;
@property (nonatomic) unsigned long long activeBytes;
@end

@implementation SampleStore

- (instancetype)initWithAnalyticsDirectory:(NSString *)analyticsDirectory {
    self = [super init];
    if (self) {
        _analyticsDir = [analyticsDirectory copy];
        _samplesDir = [analyticsDirectory stringByAppendingPathComponent:@"samples"];
        NSFileManager *fm = [NSFileManager defaultManager];
        [fm createDirectoryAtPath:_samplesDir
      withIntermediateDirectories:YES
                       attributes:nil
                            error:nil];
        [self loadManifest];
        [self acquireLock];
        if (self.state == TAStoreWriterStateWriter) {
            [self applyRetention];
        }
    }
    return self;
}

- (NSString *)analyticsDirectoryPath { return self.analyticsDir; }
- (NSString *)samplesDirectoryPath { return self.samplesDir; }
- (TAStoreWriterState)writerState { return self.state; }
- (BOOL)lockWasReclaimed { return self.reclaimed; }

- (unsigned long long)totalBytes {
    unsigned long long total = 0;
    for (NSDictionary *seg in self.manifest[@"segments"]) {
        total += [seg[@"bytes"] unsignedLongLongValue];
    }
    return total;
}

- (NSUInteger)segmentCount {
    return [self.manifest[@"segments"] count];
}

#pragma mark - Manifest

- (NSString *)manifestPath {
    return [self.samplesDir stringByAppendingPathComponent:@"manifest.json"];
}

- (void)loadManifest {
    NSData *data = [NSData dataWithContentsOfFile:[self manifestPath]];
    NSDictionary *parsed = nil;
    if (data != nil) {
        parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    }
    if ([parsed isKindOfClass:[NSDictionary class]]
            && [parsed[@"segments"] isKindOfClass:[NSArray class]]) {
        self.manifest = [parsed mutableCopy];
        self.manifest[@"segments"] = [[parsed[@"segments"] mutableCopy] ?: @[] mutableCopy];
        NSMutableArray *segs = [NSMutableArray array];
        for (NSDictionary *seg in parsed[@"segments"]) {
            [segs addObject:[seg mutableCopy]];
        }
        self.manifest[@"segments"] = segs;
        if (self.manifest[@"reclaims"] == nil) {
            self.manifest[@"reclaims"] = @0;
        }
    } else {
        self.manifest = [@{ @"format": @"academy-samples/1",
                            @"segments": [NSMutableArray array],
                            @"reclaims": @0 } mutableCopy];
    }
}

/* Atomic manifest write: tmp file, fsync, rename over the live file. */
- (void)saveManifest {
    NSData *data = [NSJSONSerialization dataWithJSONObject:self.manifest
                                                   options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys
                                                     error:nil];
    if (data == nil) {
        return;
    }
    NSString *tmp = [[self manifestPath] stringByAppendingString:@".tmp"];
    [data writeToFile:tmp atomically:NO];
    int fd = open([tmp fileSystemRepresentation], O_WRONLY);
    if (fd >= 0) {
        fsync(fd);
        close(fd);
    }
    rename([tmp fileSystemRepresentation], [[self manifestPath] fileSystemRepresentation]);
}

#pragma mark - Writer lock (S1)

- (NSString *)lockPath {
    return [self.samplesDir stringByAppendingPathComponent:@"writer.lock"];
}

- (BOOL)createLockFile {
    int fd = open([[self lockPath] fileSystemRepresentation],
                  O_CREAT | O_EXCL | O_WRONLY, 0644);
    if (fd < 0) {
        return NO;
    }
    NSString *payload = [NSString stringWithFormat:@"{\"pid\": %d, \"heartbeat\": %.3f}",
                         getpid(), [[NSDate date] timeIntervalSince1970]];
    const char *bytes = [payload UTF8String];
    write(fd, bytes, strlen(bytes));
    fsync(fd);
    close(fd);
    return YES;
}

- (BOOL)lockIsStale {
    NSData *data = [NSData dataWithContentsOfFile:[self lockPath]];
    if (data == nil) {
        return YES;
    }
    NSDictionary *info = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![info isKindOfClass:[NSDictionary class]]) {
        return YES; /* unparsable lock: stale, per the reference */
    }
    NSTimeInterval heartbeat = [info[@"heartbeat"] doubleValue];
    pid_t pid = (pid_t)[info[@"pid"] intValue];
    if (heartbeat <= 0 || pid <= 0) {
        return YES;
    }
    if ([[NSDate date] timeIntervalSince1970] - heartbeat < kStaleAfterSeconds) {
        return NO;
    }
    if (kill(pid, 0) == 0 || errno == EPERM) {
        return NO; /* pid alive (or owned by someone else): not stale */
    }
    return YES;
}

- (void)acquireLock {
    if ([self createLockFile]) {
        self.state = TAStoreWriterStateWriter;
        return;
    }
    if (![self lockIsStale]) {
        self.state = TAStoreWriterStateRefused; /* refused, never merged */
        return;
    }
    unlink([[self lockPath] fileSystemRepresentation]); /* reclaim, recorded */
    self.manifest[@"reclaims"] = @([self.manifest[@"reclaims"] integerValue] + 1);
    self.reclaimed = YES;
    if ([self createLockFile]) {
        self.state = TAStoreWriterStateWriter;
        [self saveManifest];
    } else {
        self.state = TAStoreWriterStateRefused;
    }
}

- (void)heartbeatNow {
    if (self.state != TAStoreWriterStateWriter) {
        return;
    }
    NSString *payload = [NSString stringWithFormat:@"{\"pid\": %d, \"heartbeat\": %.3f}",
                         getpid(), [[NSDate date] timeIntervalSince1970]];
    NSString *tmp = [[self lockPath] stringByAppendingString:@".tmp"];
    [payload writeToFile:tmp atomically:NO encoding:NSUTF8StringEncoding error:nil];
    int fd = open([tmp fileSystemRepresentation], O_WRONLY);
    if (fd >= 0) {
        fsync(fd);
        close(fd);
    }
    rename([tmp fileSystemRepresentation], [[self lockPath] fileSystemRepresentation]);
}

#pragma mark - Segments (S2–S4)

+ (NSString *)utcStamp {
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"UTC"];
    formatter.dateFormat = @"yyyyMMdd-HHmmss";
    return [formatter stringFromDate:[NSDate date]];
}

+ (NSString *)sha256HexOfFile:(NSString *)path {
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:path];
    if (handle == nil) {
        return nil;
    }
    CC_SHA256_CTX ctx;
    CC_SHA256_Init(&ctx);
    while (YES) {
        NSData *chunk = [handle readDataOfLength:65536];
        if (chunk.length == 0) {
            break;
        }
        CC_SHA256_Update(&ctx, chunk.bytes, (CC_LONG)chunk.length);
    }
    [handle closeFile];
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(digest, &ctx);
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) {
        [hex appendFormat:@"%02x", digest[i]];
    }
    return hex;
}

- (NSMutableDictionary *)activeEntry {
    NSArray *segs = self.manifest[@"segments"];
    return segs.count > 0 ? segs[segs.count - 1] : nil;
}

- (void)openSegment {
    NSString *stamp = [[self class] utcStamp];
    NSString *name = [NSString stringWithFormat:@"samples-%@.jsonl", stamp];
    NSMutableDictionary *last = [self activeEntry];
    if (last != nil && [last[@"name"] isEqualToString:name]) {
        name = [NSString stringWithFormat:@"samples-%@-%d.jsonl", stamp, getpid()];
    }
    NSString *path = [self.samplesDir stringByAppendingPathComponent:name];
    [[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:nil];
    self.activeHandle = [NSFileHandle fileHandleForWritingAtPath:path];
    [self.activeHandle seekToEndOfFile];
    self.activeName = name;
    self.activeHour = [stamp substringToIndex:11]; /* yyyyMMdd-HH */
    self.activeBytes = 0;
    NSMutableDictionary *entry = [@{ @"name": name,
                                     @"bytes": @0,
                                     @"lines": @0,
                                     @"sha256": [NSNull null],
                                     @"sealed": @NO } mutableCopy];
    [self.manifest[@"segments"] addObject:entry];
    [self saveManifest];
}

- (void)sealActive {
    if (self.activeHandle == nil) {
        return;
    }
    [self.activeHandle synchronizeFile];
    [self.activeHandle closeFile];
    self.activeHandle = nil;
    NSString *path = [self.samplesDir stringByAppendingPathComponent:self.activeName];
    NSMutableDictionary *entry = [self activeEntry];
    unsigned long long size = [[[NSFileManager defaultManager]
        attributesOfItemAtPath:path error:nil] fileSize];
    entry[@"bytes"] = @(size);
    NSString *hash = [[self class] sha256HexOfFile:path];
    entry[@"sha256"] = hash != nil ? hash : [NSNull null];
    entry[@"sealed"] = @YES;
    self.activeName = nil;
    self.activeHour = nil;
    self.activeBytes = 0;
    [self saveManifest];
}

- (BOOL)appendLines:(NSArray<NSString *> *)jsonLines {
    if (self.state != TAStoreWriterStateWriter || jsonLines.count == 0) {
        return NO;
    }
    NSMutableData *batch = [NSMutableData data];
    for (NSString *line in jsonLines) {
        [batch appendData:[[line stringByAppendingString:@"\n"]
                           dataUsingEncoding:NSUTF8StringEncoding]];
    }
    NSString *stamp = [[self class] utcStamp];
    NSString *hour = [stamp substringToIndex:11];
    if (self.activeHandle == nil) {
        [self openSegment];
    } else if (self.activeBytes + batch.length > kRotateBytes
               || ![hour isEqualToString:self.activeHour]) {
        [self sealActive];
        [self openSegment];
    }
    [self.activeHandle writeData:batch];
    [self.activeHandle synchronizeFile]; /* S5: fsync per batch */
    self.activeBytes += batch.length;
    NSMutableDictionary *entry = [self activeEntry];
    entry[@"bytes"] = @(self.activeBytes);
    entry[@"lines"] = @([entry[@"lines"] unsignedLongLongValue] + jsonLines.count);
    [self applyRetention];
    [self saveManifest];
    return YES;
}

#pragma mark - Retention (S3)

- (void)applyRetention {
    NSMutableArray *segs = self.manifest[@"segments"];
    unsigned long long total = [self totalBytes];
    BOOL changed = NO;
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"UTC"];
    formatter.dateFormat = @"yyyyMMdd-HHmmss";
    NSMutableArray *kept = [NSMutableArray array];
    for (NSUInteger i = 0; i < segs.count; i++) {
        NSDictionary *seg = segs[i];
        BOOL isActive = (self.activeHandle != nil && i == segs.count - 1);
        BOOL sealed = [seg[@"sealed"] boolValue];
        BOOL ageOut = NO;
        if (sealed && [seg[@"name"] length] >= 23) {
            NSString *stampPart = [seg[@"name"] substringWithRange:NSMakeRange(8, 15)];
            NSDate *stampDate = [formatter dateFromString:stampPart];
            if (stampDate != nil
                    && [[NSDate date] timeIntervalSinceDate:stampDate] > kRetainSeconds) {
                ageOut = YES;
            }
        }
        if (!isActive && sealed && (ageOut || total > kRetainBytes)) {
            [[NSFileManager defaultManager]
                removeItemAtPath:[self.samplesDir stringByAppendingPathComponent:seg[@"name"]]
                           error:nil];
            total -= [seg[@"bytes"] unsignedLongLongValue];
            changed = YES;
        } else {
            [kept addObject:seg];
        }
    }
    if (changed) {
        self.manifest[@"segments"] = kept;
    }
}

#pragma mark - Owner operations

- (BOOL)deleteAllSamples {
    if (self.state != TAStoreWriterStateWriter) {
        return NO; /* a reader never deletes the writer's store */
    }
    if (self.activeHandle != nil) {
        [self.activeHandle closeFile];
        self.activeHandle = nil;
        self.activeName = nil;
        self.activeHour = nil;
        self.activeBytes = 0;
    }
    BOOL ok = YES;
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSDictionary *seg in self.manifest[@"segments"]) {
        if (![fm removeItemAtPath:[self.samplesDir stringByAppendingPathComponent:seg[@"name"]]
                            error:nil]) {
            ok = NO;
        }
    }
    self.manifest[@"segments"] = [NSMutableArray array];
    [self saveManifest];
    return ok;
}

- (void)sealAndClose {
    if (self.state != TAStoreWriterStateWriter) {
        return;
    }
    [self sealActive];
    unlink([[self lockPath] fileSystemRepresentation]);
    [self saveManifest];
}

@end
