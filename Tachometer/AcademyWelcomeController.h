#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

/* AcademyWelcomeController — the SDS-8 welcome sheet: registered icon,
 * app name, version read from the bundle's own Info.plist at runtime
 * (SDS-10 §10.2.2), the byte-identical startup sound played once
 * (SDS-10 §10.3). Shared Academy component, Tachometer instance. */
@interface AcademyWelcomeController : NSWindowController
+ (NSString *)bundleVersionLine;
- (void)presentAsSheetOnWindow:(NSWindow *)parentWindow;
@end

NS_ASSUME_NONNULL_END
