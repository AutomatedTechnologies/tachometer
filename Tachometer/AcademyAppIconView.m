#import "AcademyAppIconView.h"

@implementation AcademyAppIconView

- (NSImage *)iconImage {
    NSImage *image = [NSApplication sharedApplication].applicationIconImage;
    if (image == nil) {
        image = [[NSWorkspace sharedWorkspace] iconForFile:[[NSBundle mainBundle] bundlePath]];
    }
    return image;
}

- (BOOL)isFlipped {
    return YES;
}

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];
    NSImage *image = [self iconImage];
    if (image == nil) {
        return;
    }
    NSSize imageSize = [image size];
    if (imageSize.width <= 0 || imageSize.height <= 0) {
        return;
    }
    CGFloat scale = MIN(NSWidth(self.bounds) / imageSize.width,
                        NSHeight(self.bounds) / imageSize.height);
    NSSize drawSize = NSMakeSize(imageSize.width * scale, imageSize.height * scale);
    NSRect drawRect = NSMakeRect((NSWidth(self.bounds) - drawSize.width) / 2.0,
                                 (NSHeight(self.bounds) - drawSize.height) / 2.0,
                                 drawSize.width, drawSize.height);
    [image drawInRect:drawRect
             fromRect:NSZeroRect
            operation:NSCompositingOperationSourceOver
             fraction:1.0
       respectFlipped:YES
                hints:nil];
}

@end
