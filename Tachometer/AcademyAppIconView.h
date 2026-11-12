#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

/* AcademyAppIconView — draws the bundle's own AppIcon, aspect-fit and
 * centered. The composition is the app's registered icon; renditions may
 * differ per surface, the composition may not (SDS-10 §10.1.2). Shared
 * Academy component (KisMac/Snowfell lineage). */
@interface AcademyAppIconView : NSView
@end

NS_ASSUME_NONNULL_END
