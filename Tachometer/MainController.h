#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

/* MainController — Tachometer's window: the live per-process table, the
 * session summary (idle baseline vs view-switch windows), the disclosure
 * pane, and the sampling controls. Sampling runs only while the app is
 * open and not paused — closing the app is the off switch. */
@interface MainController : NSWindowController <NSTableViewDataSource, NSTableViewDelegate>
- (void)showWindowAndStart;
- (void)toggleDisclosure;
- (void)shutdown; /* seals the active segment and releases the writer lock */
@end

NS_ASSUME_NONNULL_END
