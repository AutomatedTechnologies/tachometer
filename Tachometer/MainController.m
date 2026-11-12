#import "MainController.h"
#import "ProcSampler.h"
#import "SampleStore.h"
#import "BudgetScorer.h"
#import "CPUMath.h"

/* The analytics store root is fixed by the merge contract (files/36 §2):
 * the component's data lives under the analytics identity, whatever the
 * hosting app's display name. */
static NSString * const kAnalyticsId = @"com.detroitautomationacademy.analytics";

@interface MainController ()
@property (nonatomic, strong) ProcSampler *sampler;
@property (nonatomic, strong) SampleStore *store;
@property (nonatomic, strong) BudgetScorer *scorer;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, strong) NSArray<TAProcessRow *> *rows;
@property (nonatomic, strong) NSTableView *table;
@property (nonatomic, strong) NSTextField *statusField;
@property (nonatomic, strong) NSTextField *summaryField;
@property (nonatomic, strong) NSTextField *budgetsField;
@property (nonatomic, strong) NSTextView *disclosureView;
@property (nonatomic, strong) NSButton *pauseButton;
@property (nonatomic, strong) NSButton *deleteButton;
@property (nonatomic) BOOL sampling;
@property (nonatomic, strong) NSDate *sessionStart;
/* Session series per family bundle id: @[ @[ts, pctTotalFamily], ... ] */
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSMutableArray<NSArray<NSNumber *> *> *> *seriesByFamily;
@property (nonatomic, strong) NSMutableArray<NSDate *> *marks;
/* 5-second file aggregation: pidKey -> @[sumPctOne, sumPctTotal, count, row snapshot, lastRssBytes] */
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSMutableArray *> *fileAccum;
@property (nonatomic) NSInteger ticksSinceFileWrite;
@property (nonatomic) NSInteger ticksTotal;
@end

@implementation MainController

- (instancetype)init {
    NSWindow *window = [[NSWindow alloc]
        initWithContentRect:NSMakeRect(0, 0, 780, 560)
                  styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                          | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
                    backing:NSBackingStoreBuffered
                      defer:NO];
    self = [super initWithWindow:window];
    if (self) {
        _sampler = [[ProcSampler alloc] init];
        NSArray<NSString *> *base = NSSearchPathForDirectoriesInDomains(
            NSApplicationSupportDirectory, NSUserDomainMask, YES);
        NSString *appSupport = base.count > 0 ? base[0]
            : [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support"];
        NSString *analyticsDir = [appSupport stringByAppendingPathComponent:kAnalyticsId];
        _store = [[SampleStore alloc] initWithAnalyticsDirectory:analyticsDir];
        _scorer = [[BudgetScorer alloc] initWithAnalyticsDirectory:analyticsDir
                                                samplesDirectory:_store.samplesDirectoryPath];
        _rows = @[];
        _seriesByFamily = [NSMutableDictionary dictionary];
        _marks = [NSMutableArray array];
        _fileAccum = [NSMutableDictionary dictionary];
        _sessionStart = [NSDate date];
        [self buildContent];
    }
    return self;
}

- (NSButton *)buttonWithTitle:(NSString *)title frame:(NSRect)frame
                       action:(SEL)action key:(NSString *)key {
    NSButton *button = [[NSButton alloc] initWithFrame:frame];
    [button setTitle:title];
    [button setBezelStyle:NSBezelStyleRounded];
    [button setTarget:self];
    [button setAction:action];
    if (key != nil) {
        [button setKeyEquivalent:key];
        [button setKeyEquivalentModifierMask:NSEventModifierFlagCommand];
    }
    return button;
}

- (void)buildContent {
    NSWindow *window = [self window];
    [window setTitle:@"Tachometer"];
    [window center];
    NSView *content = [window contentView];

    self.statusField = [NSTextField labelWithString:@"Sampling…"];
    [self.statusField setFont:[NSFont systemFontOfSize:12]];
    [self.statusField setFrame:NSMakeRect(16, 524, 500, 18)];
    [content addSubview:self.statusField];

    self.pauseButton = [self buttonWithTitle:@"Pause"
                                       frame:NSMakeRect(528, 518, 84, 28)
                                      action:@selector(toggleSampling:) key:nil];
    [content addSubview:self.pauseButton];

    NSButton *markButton = [self buttonWithTitle:@"Mark view switch"
                                           frame:NSMakeRect(620, 518, 144, 28)
                                          action:@selector(markNow:) key:@"j"];
    [content addSubview:markButton];

    NSTableColumn *appCol = [[NSTableColumn alloc] initWithIdentifier:@"app"];
    [appCol setTitle:@"App"];
    [appCol setWidth:160];
    NSTableColumn *roleCol = [[NSTableColumn alloc] initWithIdentifier:@"role"];
    [roleCol setTitle:@"Process (role)"];
    [roleCol setWidth:110];
    NSTableColumn *pidCol = [[NSTableColumn alloc] initWithIdentifier:@"pid"];
    [pidCol setTitle:@"PID"];
    [pidCol setWidth:55];
    NSTableColumn *oneCol = [[NSTableColumn alloc] initWithIdentifier:@"one"];
    [oneCol setTitle:@"% of one thread"];
    [oneCol setWidth:120];
    NSTableColumn *totalCol = [[NSTableColumn alloc] initWithIdentifier:@"total"];
    [totalCol setTitle:@"% of all hardware"];
    [totalCol setWidth:130];
    NSTableColumn *rssCol = [[NSTableColumn alloc] initWithIdentifier:@"rss"];
    [rssCol setTitle:@"Memory"];
    [rssCol setWidth:110];

    self.table = [[NSTableView alloc] initWithFrame:NSMakeRect(16, 262, 748, 246)];
    [self.table addTableColumn:appCol];
    [self.table addTableColumn:roleCol];
    [self.table addTableColumn:pidCol];
    [self.table addTableColumn:oneCol];
    [self.table addTableColumn:totalCol];
    [self.table addTableColumn:rssCol];
    [self.table setDataSource:self];
    [self.table setDelegate:self];
    [self.table setUsesAlternatingRowBackgroundColors:YES];
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(16, 262, 748, 246)];
    [scroll setDocumentView:self.table];
    [scroll setHasVerticalScroller:YES];
    [scroll setBorderType:NSBezelBorder];
    [content addSubview:scroll];

    NSTextField *summaryTitle = [NSTextField labelWithString:@"Session summary — idle vs view-switch windows"];
    [summaryTitle setFont:[NSFont systemFontOfSize:12 weight:NSFontWeightSemibold]];
    [summaryTitle setFrame:NSMakeRect(16, 236, 500, 18)];
    [content addSubview:summaryTitle];

    self.summaryField = [NSTextField wrappingLabelWithString:@"Collecting samples…"];
    [self.summaryField setFont:[NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular]];
    [self.summaryField setFrame:NSMakeRect(16, 178, 748, 54)];
    [content addSubview:self.summaryField];

    NSTextField *budgetsTitle = [NSTextField labelWithString:@"Resource budgets — scored from the stored samples (report only, nothing is enforced)"];
    [budgetsTitle setFont:[NSFont systemFontOfSize:12 weight:NSFontWeightSemibold]];
    [budgetsTitle setFrame:NSMakeRect(16, 152, 640, 18)];
    [content addSubview:budgetsTitle];

    self.budgetsField = [NSTextField wrappingLabelWithString:@"Not scored yet."];
    [self.budgetsField setFont:[NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular]];
    [self.budgetsField setFrame:NSMakeRect(16, 104, 748, 44)];
    [content addSubview:self.budgetsField];

    NSButton *aboutButton = [self buttonWithTitle:@"What this measures"
                                            frame:NSMakeRect(16, 68, 150, 28)
                                           action:@selector(toggleDisclosurePressed:) key:nil];
    [content addSubview:aboutButton];

    self.deleteButton = [self buttonWithTitle:@"Delete stored samples"
                                        frame:NSMakeRect(176, 68, 170, 28)
                                       action:@selector(deleteSamples:) key:nil];
    [content addSubview:self.deleteButton];

    NSButton *scoreButton = [self buttonWithTitle:@"Score budgets"
                                            frame:NSMakeRect(356, 68, 120, 28)
                                           action:@selector(scoreBudgetsPressed:) key:nil];
    [content addSubview:scoreButton];

    NSTextView *disclosure = [[NSTextView alloc] initWithFrame:NSMakeRect(16, 8, 748, 52)];
    [disclosure setEditable:NO];
    [disclosure setFont:[NSFont systemFontOfSize:11]];
    [disclosure setString:[self disclosureText]];
    [disclosure setHidden:YES];
    self.disclosureView = disclosure;
    [content addSubview:disclosure];

    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(appResignedActive:)
               name:NSApplicationDidResignActiveNotification
             object:nil];
}

- (NSString *)disclosureText {
    return [NSString stringWithFormat:
        @"What this measures, in plain language. Tachometer reads the CPU counters and "
         "memory size of Academy apps (and itself) from macOS, twice a second, and works "
         "out what share of this machine each process used. Every process carries a role "
         "label — shell, renderer, gpu, helper — so an app's cost can be told apart piece "
         "by piece. Samples are written as plain text to %@ in sealed segments (a new "
         "segment every 8 MB or hour; the store keeps at most 256 MB and nothing older "
         "than 7 days). One writer at a time: if another copy of Tachometer is already "
         "writing, this one only watches. The budget scores are computed on this machine "
         "from those samples and written to verdicts.json beside the samples; the scorer "
         "only reports — it never throttles or stops anything. Tachometer's own budget "
         "(2%% of one thread, 50 MB) is scored from its own samples like every other "
         "app's. Nothing is sent anywhere: this app contains no network code. Sampling "
         "runs only while Tachometer is open — quitting the app is the off switch. "
         "\"Mark view switch\" (⌘J) stamps the moment you change views in another app, "
         "so the summary can separate steady-state cost from view-switch spikes; a mark "
         "is also stamped automatically when you click away from this window.",
        self.store.samplesDirectoryPath];
}

- (void)showWindowAndStart {
    [self showWindow:nil];
    [[self window] makeKeyAndOrderFront:nil];
    if (self.store.writerState == TAStoreWriterStateRefused) {
        /* S1: a live writer exists. This instance is a reader: it shows
         * live figures but writes nothing — refused, never merged. */
        [self.deleteButton setEnabled:NO];
        [self.statusField setStringValue:
            @"Another Tachometer is already writing samples — this window only watches (nothing is written)."];
    }
    self.sampling = YES;
    self.timer = [NSTimer scheduledTimerWithTimeInterval:0.5
                                                  target:self
                                                selector:@selector(tick:)
                                                userInfo:nil
                                                 repeats:YES];
    [self tick:nil];
}

- (void)shutdown {
    [self.timer invalidate];
    [self.store sealAndClose];
}

- (void)toggleSampling:(id)sender {
    self.sampling = !self.sampling;
    [self.pauseButton setTitle:self.sampling ? @"Pause" : @"Resume"];
    [self.statusField setStringValue:self.sampling
        ? @"Sampling…" : @"Paused — no samples are being read or written."];
}

- (void)toggleDisclosure {
    [self.disclosureView setHidden:![self.disclosureView isHidden]];
}

- (void)toggleDisclosurePressed:(id)sender {
    [self toggleDisclosure];
}

- (void)deleteSamples:(id)sender {
    if (self.store.writerState != TAStoreWriterStateWriter) {
        [self.statusField setStringValue:
            @"This window is not the store's writer — stored samples are left untouched."];
        return;
    }
    BOOL ok = [self.store deleteAllSamples];
    [self.statusField setStringValue:ok
        ? @"Stored samples deleted."
        : @"Some stored sample files could not be deleted."];
}

- (void)scoreBudgetsPressed:(id)sender {
    [self scoreBudgets];
}

/* The scorer is a reader of the store and the sole writer of
 * verdicts.json; scoring runs on demand and every 60 s while sampling. */
- (void)scoreBudgets {
    NSArray<NSDictionary *> *verdicts = [self.scorer scoreNow];
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    for (NSDictionary *v in verdicts) {
        if ([v[@"verdict"] isEqualToString:@"NO DATA"]) {
            [lines addObject:[NSString stringWithFormat:@"%@: NO DATA", v[@"id"]]];
        } else {
            NSString *line = [NSString stringWithFormat:
                @"%@: %@ · cpu sustained %@%% · peak %@%% · memory peak %@ bytes",
                v[@"id"], v[@"verdict"], v[@"cpu_sustained"], v[@"cpu_peak"],
                v[@"rss_peak_bytes"]];
            NSArray *breaches = v[@"breaches"];
            if ([breaches isKindOfClass:[NSArray class]] && breaches.count > 0) {
                line = [line stringByAppendingString:
                    [NSString stringWithFormat:@" · [%@]",
                     [breaches componentsJoinedByString:@"; "]]];
            }
            [lines addObject:line];
        }
    }
    [self.budgetsField setStringValue:lines.count > 0
        ? [lines componentsJoinedByString:@"\n"] : @"No budgets in the table."];
}

/* A mark separates "before the switch" from "after the switch" in the
 * session series: steady state is measured away from marks, transition
 * cost inside the 2 seconds after each mark. Marks persist to
 * marks.jsonl BESIDE the samples store — never inside a samples
 * segment, whose every line is a sample record by contract. */
- (void)recordMarkWithKind:(NSString *)kind {
    NSDate *now = [NSDate date];
    [self.marks addObject:now];
    if (self.store.writerState != TAStoreWriterStateWriter) {
        return;
    }
    NSString *line = [NSString stringWithFormat:
        @"{\"ts\":%.3f,\"kind\":\"%@\"}", [now timeIntervalSince1970], kind];
    NSString *path = [self.store.analyticsDirectoryPath
                      stringByAppendingPathComponent:@"marks.jsonl"];
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:path]) {
        [fm createFileAtPath:path contents:nil attributes:nil];
    }
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
    [handle seekToEndOfFile];
    [handle writeData:[[line stringByAppendingString:@"\n"]
                       dataUsingEncoding:NSUTF8StringEncoding]];
    [handle closeFile];
}

- (void)markNow:(id)sender {
    [self recordMarkWithKind:@"button"];
}

- (void)appResignedActive:(NSNotification *)note {
    if (self.sampling) {
        [self recordMarkWithKind:@"focus-change"];
    }
}

+ (NSString *)jsonEscaped:(NSString *)value {
    NSString *escaped = [value stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"];
    escaped = [escaped stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
    return escaped;
}

- (void)tick:(NSTimer *)timer {
    if (!self.sampling) {
        return;
    }
    NSArray<TAProcessRow *> *rows = [self.sampler sample];
    self.rows = rows;
    [self.table reloadData];

    NSDate *now = [NSDate date];
    double ts = [now timeIntervalSince1970];

    /* Family totals for the session series. */
    NSMutableDictionary<NSString *, NSNumber *> *familyTotal = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSString *> *familyName = [NSMutableDictionary dictionary];
    for (TAProcessRow *row in rows) {
        double acc = [familyTotal[row.bundleId] doubleValue] + row.pctTotal;
        familyTotal[row.bundleId] = @(acc);
        if (familyName[row.bundleId] == nil) {
            familyName[row.bundleId] = row.appName;
        }
        /* File aggregation per process (slot 4 = last RSS in window:
         * memory is a gauge, reported as last seen, not averaged). */
        NSString *pidKey = [NSString stringWithFormat:@"%d:%@", row.pid, row.bundleId];
        NSMutableArray *slot = self.fileAccum[pidKey];
        if (slot == nil) {
            slot = [NSMutableArray arrayWithArray:@[ @0.0, @0.0, @0, row, @(row.rssBytes) ]];
            self.fileAccum[pidKey] = slot;
        }
        slot[0] = @([slot[0] doubleValue] + row.pctOneThread);
        slot[1] = @([slot[1] doubleValue] + row.pctTotal);
        slot[2] = @([slot[2] integerValue] + 1);
        slot[3] = row;
        slot[4] = @(row.rssBytes);
    }
    for (NSString *bundleId in familyTotal) {
        NSMutableArray *series = self.seriesByFamily[bundleId];
        if (series == nil) {
            series = [NSMutableArray array];
            self.seriesByFamily[bundleId] = series;
        }
        [series addObject:@[ @(ts), familyTotal[bundleId] ]];
        (void)familyName;
    }

    /* Every 10 ticks (5 s): flush per-process window means as contract
     * sample records {ts, app, proc, pid, cpu_pct_thread, rss_bytes}
     * (files/36 §3) plus pct_total as a scorer-ignored extra the UI's
     * whole-machine figures use. One batch, one fsync (S5). */
    self.ticksSinceFileWrite += 1;
    self.ticksTotal += 1;
    if (self.ticksSinceFileWrite >= 10) {
        self.ticksSinceFileWrite = 0;
        NSMutableArray<NSString *> *lines = [NSMutableArray array];
        for (NSString *pidKey in self.fileAccum) {
            NSMutableArray *slot = self.fileAccum[pidKey];
            NSInteger count = [slot[2] integerValue];
            if (count == 0) {
                continue;
            }
            TAProcessRow *row = slot[3];
            NSString *line = [NSString stringWithFormat:
                @"{\"ts\":%.3f,\"app\":\"%@\",\"proc\":\"%@\",\"pid\":%d,"
                 "\"cpu_pct_thread\":%.3f,\"rss_bytes\":%llu,\"pct_total\":%.3f}",
                ts,
                [[self class] jsonEscaped:row.bundleId],
                [[self class] jsonEscaped:row.role],
                row.pid,
                [slot[0] doubleValue] / (double)count,
                [slot[4] unsignedLongLongValue],
                [slot[1] doubleValue] / (double)count];
            [lines addObject:line];
        }
        [self.store appendLines:lines];
        [self.fileAccum removeAllObjects];
    }
    if (self.ticksTotal % 60 == 0) {
        [self.store heartbeatNow]; /* keep writer.lock fresh (S1) */
    }
    if (self.ticksTotal % 120 == 0) {
        [self scoreBudgets]; /* verdicts.json stays current while sampling */
    }

    if (self.store.writerState == TAStoreWriterStateRefused) {
        [self.statusField setStringValue:[NSString stringWithFormat:
            @"Watching only — another Tachometer holds the writer lock · %lu processes in %lu Academy app families",
            (unsigned long)rows.count, (unsigned long)familyTotal.count]];
    } else {
        [self.statusField setStringValue:[NSString stringWithFormat:
            @"Sampling — %d hardware threads · %lu processes in %lu Academy app families · store %.1f MB in %lu segments%@",
            self.sampler.logicalThreads, (unsigned long)rows.count,
            (unsigned long)familyTotal.count,
            (double)self.store.totalBytes / (1024.0 * 1024.0),
            (unsigned long)self.store.segmentCount,
            self.store.lockWasReclaimed ? @" · stale writer lock reclaimed at launch" : @""]];
    }
    [self updateSummary];
}

- (void)updateSummary {
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    NSArray<NSString *> *families = [[self.seriesByFamily allKeys]
        sortedArrayUsingSelector:@selector(compare:)];
    for (NSString *bundleId in families) {
        NSArray<NSArray<NSNumber *> *> *series = self.seriesByFamily[bundleId];
        if (series.count < 4) {
            continue;
        }
        /* Baseline: samples at least 5 s clear of the session start and of
         * every mark. Transition: samples within 2 s after a mark. */
        NSMutableArray<NSNumber *> *baseline = [NSMutableArray array];
        NSMutableArray<NSNumber *> *transition = [NSMutableArray array];
        double startTs = [self.sessionStart timeIntervalSince1970];
        for (NSArray<NSNumber *> *point in series) {
            double ts = [point[0] doubleValue];
            double value = [point[1] doubleValue];
            BOOL nearMark = NO;
            BOOL inTransition = NO;
            for (NSDate *mark in self.marks) {
                double delta = ts - [mark timeIntervalSince1970];
                if (delta >= 0 && delta <= 2.0) {
                    inTransition = YES;
                }
                if (delta > -1.0 && delta < 5.0) {
                    nearMark = YES;
                }
            }
            if (inTransition) {
                [transition addObject:@(value)];
            } else if (!nearMark && ts - startTs >= 5.0) {
                [baseline addObject:@(value)];
            }
        }
        NSString *name = bundleId;
        for (TAProcessRow *row in self.rows) {
            if ([row.bundleId isEqualToString:bundleId]) {
                name = row.appName;
                break;
            }
        }
        if (baseline.count == 0) {
            [lines addObject:[NSString stringWithFormat:
                @"%@: collecting steady-state samples…", name]];
            continue;
        }
        double *buf = malloc(sizeof(double) * baseline.count);
        for (NSUInteger i = 0; i < baseline.count; i++) {
            buf[i] = [baseline[i] doubleValue];
        }
        double median = ta_median(buf, (int)baseline.count);
        free(buf);
        NSString *line = [NSString stringWithFormat:
            @"%@: idle median %.2f%% of all hardware (%.1f%% of one thread)",
            name, median, median * self.sampler.logicalThreads];
        if (transition.count > 0) {
            double sum = 0.0, peak = 0.0;
            for (NSNumber *v in transition) {
                sum += [v doubleValue];
                peak = MAX(peak, [v doubleValue]);
            }
            line = [line stringByAppendingString:[NSString stringWithFormat:
                @" · view-switch windows: mean %.2f%%, peak %.2f%% of all hardware",
                sum / (double)transition.count, peak]];
        } else {
            line = [line stringByAppendingString:
                @" · no view-switch marks yet (⌘J, or click into the app and switch views)"];
        }
        [lines addObject:line];
    }
    if (lines.count == 0) {
        [self.summaryField setStringValue:@"Collecting samples…"];
    } else {
        [self.summaryField setStringValue:[lines componentsJoinedByString:@"\n"]];
    }
}

#pragma mark - NSTableView

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return (NSInteger)self.rows.count;
}

- (id)tableView:(NSTableView *)tableView
    objectValueForTableColumn:(NSTableColumn *)tableColumn
                          row:(NSInteger)rowIndex {
    TAProcessRow *row = self.rows[(NSUInteger)rowIndex];
    NSString *identifier = [tableColumn identifier];
    if ([identifier isEqualToString:@"app"]) {
        return row.isSelf ? [row.appName stringByAppendingString:@" (this app)"] : row.appName;
    }
    if ([identifier isEqualToString:@"role"]) {
        return row.role;
    }
    if ([identifier isEqualToString:@"pid"]) {
        return @(row.pid);
    }
    if ([identifier isEqualToString:@"one"]) {
        return [NSString stringWithFormat:@"%.1f%%", row.pctOneThread];
    }
    if ([identifier isEqualToString:@"total"]) {
        return [NSString stringWithFormat:@"%.2f%%", row.pctTotal];
    }
    if ([identifier isEqualToString:@"rss"]) {
        return [NSString stringWithFormat:@"%.1f MB",
                (double)row.rssBytes / (1024.0 * 1024.0)];
    }
    return nil;
}

@end
