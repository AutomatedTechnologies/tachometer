#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/* BudgetScorer — the report-first budget scorer (files/36 §5), mirrored
 * from the staged reference (budget_scorer.py). READER of the samples
 * store: it opens segments read-only via the manifest and never writes
 * samples. SOLE WRITER of verdicts.json in the analytics directory —
 * readers of verdicts never write it.
 *
 * Semantics, identical to the reference: per timestamp, cpu/rss sum
 * across the budget's selected processes; sustained = mean of the
 * per-timestamp sums, peak = max. A budget with no matching records
 * reports NO DATA — never a silent PASS. The scorer enforces nothing. */
@interface BudgetScorer : NSObject
- (instancetype)initWithAnalyticsDirectory:(NSString *)analyticsDirectory
                            samplesDirectory:(NSString *)samplesDirectory;
/* Scores the store now, writes verdicts.json, returns the verdict
 * dictionaries ({id, verdict, cpu_sustained, cpu_peak, rss_peak_bytes,
 * breaches}) in budget-table order. */
- (NSArray<NSDictionary *> *)scoreNow;
@property (nonatomic, readonly, copy) NSString *verdictsFilePath;
@end

NS_ASSUME_NONNULL_END
