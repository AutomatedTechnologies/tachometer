#import "AppDelegate.h"
#import "MainController.h"
#import "AcademyWelcomeController.h"

@interface AppDelegate ()
@property (nonatomic, strong) MainController *mainController;
@property (nonatomic, strong) AcademyWelcomeController *welcomeController;
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    [NSApp setMainMenu:[self buildMenu]];
    self.mainController = [[MainController alloc] init];
    [self.mainController showWindowAndStart];
    /* SDS-8 welcome as a sheet on the main window, sound once (§10.3). */
    self.welcomeController = [[AcademyWelcomeController alloc] init];
    [self.welcomeController presentAsSheetOnWindow:[self.mainController window]];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    return YES;
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    /* Seal the active segment (hashed into the manifest) and release the
     * writer lock so the next launch is a clean single writer. */
    [self.mainController shutdown];
}

/* SDS-10 §10.4: a real menu bar, every item wired. App menu carries
 * About (standard panel — its version is read from the bundle's own
 * Info.plist) and Quit ⌘Q; File carries Close Window ⌘W; Help carries
 * the disclosure pane toggle. */
- (NSMenu *)buildMenu {
    NSMenu *mainMenu = [[NSMenu alloc] init];

    NSMenuItem *appItem = [[NSMenuItem alloc] init];
    NSMenu *appMenu = [[NSMenu alloc] initWithTitle:@"Tachometer"];
    [appMenu addItemWithTitle:@"About Tachometer"
                       action:@selector(orderFrontStandardAboutPanel:)
                keyEquivalent:@""];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:@"Hide Tachometer"
                       action:@selector(hide:)
                keyEquivalent:@"h"];
    [appMenu addItemWithTitle:@"Quit Tachometer"
                       action:@selector(terminate:)
                keyEquivalent:@"q"];
    [appItem setSubmenu:appMenu];
    [mainMenu addItem:appItem];

    NSMenuItem *fileItem = [[NSMenuItem alloc] init];
    NSMenu *fileMenu = [[NSMenu alloc] initWithTitle:@"File"];
    [fileMenu addItemWithTitle:@"Close Window"
                        action:@selector(performClose:)
                 keyEquivalent:@"w"];
    [fileItem setSubmenu:fileMenu];
    [mainMenu addItem:fileItem];

    NSMenuItem *helpItem = [[NSMenuItem alloc] init];
    NSMenu *helpMenu = [[NSMenu alloc] initWithTitle:@"Help"];
    NSMenuItem *whatItem = [helpMenu addItemWithTitle:@"What This Measures"
                                               action:@selector(helpWhatThisMeasures:)
                                        keyEquivalent:@""];
    [whatItem setTarget:self];
    [helpItem setSubmenu:helpMenu];
    [mainMenu addItem:helpItem];

    return mainMenu;
}

- (void)helpWhatThisMeasures:(id)sender {
    [self.mainController toggleDisclosure];
}

@end
