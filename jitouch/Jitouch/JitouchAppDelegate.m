//
//  JitouchAppDelegate.m
//  Jitouch
//
//  Copyright 2021 Supasorn Suwajanakorn and Sukolsak Sakshuwong. All rights reserved.
//  Modified work Copyright 2021 Aaron Kollasch. All rights reserved.
//

#import "JitouchAppDelegate.h"
#import "Settings.h"
#import "Gesture.h"
#import "CursorWindow.h"
#import <Carbon/Carbon.h>
#import <CoreFoundation/CFPreferences.h>
#import "SystemPreferences.h"

CursorWindow *cursorWindow;
CGKeyCode keyMap[128]; // for dvorak support

@implementation JitouchAppDelegate

@synthesize window;

- (void)unloadJitouchLaunchAgent {
    NSString *plistPath = [@"~/Library/LaunchAgents/com.jitouch.Jitouch.plist" stringByStandardizingPath];
    NSArray *unloadArgs = [NSArray arrayWithObjects:@"unload",
                           plistPath,
                           nil];
    NSTask *unloadTask = [NSTask launchedTaskWithLaunchPath:@"/bin/launchctl" arguments:unloadArgs];
    [unloadTask waitUntilExit];
}

#pragma mark - Menu

- (BOOL)validateMenuItem:(NSMenuItem *)item {
    return YES;
}

- (void)showIcon {
    theMenu = [[[NSMenu alloc] initWithTitle:@"Contextual Menu"] autorelease];
    [self rebuildMenu];

    NSStatusBar *bar = [NSStatusBar systemStatusBar];
    theItem = [bar statusItemWithLength:NSVariableStatusItemLength];
    [theItem retain];
    [self updateIconImage];
    [theItem setHighlightMode:YES];
    [theItem setMenu:theMenu];
}

// The permission item only exists while Jitouch is not trusted, so the menu is
// rebuilt instead of being edited by index.
- (void)rebuildMenu {
    if (theMenu == nil) {
        return;
    }
    [theMenu removeAllItems];
    [theMenu addItemWithTitle:(enAll ? @"Turn Jitouch Off" : @"Turn Jitouch On")
                       action:@selector(switchChange:) keyEquivalent:@""];
    [theMenu addItemWithTitle:@"Open Preferences..." action:@selector(preferences:) keyEquivalent:@""];
    if (!AXIsProcessTrusted()) {
        [theMenu addItemWithTitle:@"Grant Accessibility Permission…"
                           action:@selector(grantAccessibilityPermission:) keyEquivalent:@""];
    }
    [theMenu addItem:[NSMenuItem separatorItem]];
    [theMenu addItemWithTitle:@"Quit Jitouch" action:@selector(quit:) keyEquivalent:@""];
}

- (void)hideIcon {
    [[NSStatusBar systemStatusBar] removeStatusItem:theItem];
    [theItem release];
    theItem = nil;
}

- (void)updateIconImage {
    if (enAll) {
        NSImage *img = [NSImage imageNamed:@"logosmall"];
        [img setTemplate:YES];
        [theItem setImage:img];
    } else {
        NSImage *img = [NSImage imageNamed:@"logosmalloff"];
        [img setTemplate:YES];
        [theItem setImage:img];
    }
}

- (void)preferences:(id)sender  {
    NSString *prefPath = [@"~/Library/PreferencePanes/Jitouch.prefPane" stringByExpandingTildeInPath];
    if (![[NSFileManager defaultManager] fileExistsAtPath:prefPath]) {
        prefPath = @"/Library/PreferencePanes/Jitouch.prefPane";
    }

    if ([[NSFileManager defaultManager] fileExistsAtPath:prefPath]) {
        [[NSWorkspace sharedWorkspace] openFile:prefPath];
    } else {
        NSAlert *alert = [[NSAlert alloc] init];
        [alert setMessageText:@"Can't find the jitouch preference panel."];
        [alert setInformativeText:@"Please reinstall jitouch."];
        [alert setAlertStyle:NSAlertStyleWarning];
        [NSApp activateIgnoringOtherApps:YES];
        [alert runModal];
        [alert release];
    }
}


- (void)quit:(id)sender {
    [self unloadJitouchLaunchAgent];

    // Quit
    [NSApp terminate: sender];
}

- (void)refreshMenu {
    if (theItem == nil && [[settings objectForKey:@"ShowIcon"] intValue] == 1){
        [self showIcon];
    } else if (theItem != nil && [[settings objectForKey:@"ShowIcon"] intValue] == 0){
        [self hideIcon];
    }
    if (theItem) {
        [self rebuildMenu];
        [self updateIconImage];
    }
}

- (void)switchChange:(id)sender {
    enAll = !enAll;
    [self refreshMenu];
    [self saveSettings];

    if (!enAll)
        turnOffGestures();
}

#pragma mark - Settings

- (void)saveSettings {
    [Settings setKey:@"enAll" withInt:enAll];
    [Settings noteSettingsUpdated2];
}

- (void)settingsUpdated:(NSNotification *)aNotification {
    //[Settings loadSettings];

    [Settings loadSettings2:aNotification.userInfo]; // fixes bug in mountain lion
    [self refreshMenu];

    if (!enAll)
        turnOffGestures();
}

#pragma mark - Initialization


#pragma mark - Accessibility permission

// The pane was called "Accessibility" up to macOS 15; macOS 26 and later fold it
// into "Device Control and Data Access". The anchor still works on both.
static NSString *const kJitouchPrivacySettingsURL =
    @"x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility";

- (void)recordPermissionState {
    [Settings setKey:@"axTrusted" withInt:(AXIsProcessTrusted() ? 1 : 0)];
}

- (void)openAccessibilitySettings {
    // Showing the system prompt is what registers Jitouch in the pane: macOS adds
    // the app to the list itself, so the user only has to flip the switch.
    AXIsProcessTrustedWithOptions((CFDictionaryRef)@{(id)kAXTrustedCheckOptionPrompt: @(YES)});
    NSURL *url = [NSURL URLWithString:kJitouchPrivacySettingsURL];
    if (url) {
        [[NSWorkspace sharedWorkspace] openURL:url];
    }
}

- (void)grantAccessibilityPermission:(id)sender {
    [self openAccessibilitySettings];
    [self startPermissionWatch];
}

- (void)checkAXAPI {
    [self recordPermissionState];
    if (AXIsProcessTrusted()) {
        return;
    }
    // No custom alert: the native prompt already explains itself, is localized,
    // and its "Open System Settings" button lands on the right pane with Jitouch
    // pre-registered. We open that pane as well so the switch is one click away.
    [self openAccessibilitySettings];
    [self startPermissionWatch];
}

- (void)startPermissionWatch {
    if (permissionTimer != nil) {
        return;
    }
    permissionTimer = [[NSTimer scheduledTimerWithTimeInterval:1.0
                                                        target:self
                                                      selector:@selector(permissionTick:)
                                                      userInfo:nil
                                                       repeats:YES] retain];
}

- (void)permissionTick:(NSTimer *)timer {
    if (!AXIsProcessTrusted()) {
        return;
    }
    [timer invalidate];
    [permissionTimer release];
    permissionTimer = nil;

    NSLog(@"Accessibility permission granted; reloading gestures.");
    [self recordPermissionState];
    [self refreshMenu];
    // The event tap could not be created at launch, so build it now instead of
    // asking the user to restart Jitouch.
    [gesture reload];
    [Settings noteSettingsUpdated2];
}

/*
void languageChanged(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    for (int i = 0; i < 128; i++)
        keyMap[i] = (CGKeyCode)i;
    NSString *inputSource = (NSString*)TISGetInputSourceProperty(TISCopyCurrentKeyboardInputSource(), kTISPropertyLocalizedName);
    if ([inputSource isEqualToString:@"Dvorak"] || [inputSource isEqualToString:@"Svorak"]) {
        keyMap[13] = 43; //w -> ,
        keyMap[12] = 7;  //q -> x
        keyMap[17] = 40; //t -> k
        keyMap[4] = 38;  //h -> j
        keyMap[15] = 31; //r -> o
        keyMap[45] = 37; //n -> l
        keyMap[8] = 34; //c -> i
        keyMap[9] = 47; //v -> >
        keyMap[31] = 1; //o ->
        keyMap[37] = 45; //l -> n
        keyMap[3] = 32; // f -> u
        keyMap[40] = 17;
    } else if ([inputSource isEqualToString:@"French"]) {
        keyMap[13] = 6;  //w -> z
        keyMap[12] = 0;  //q -> a
    }
}
*/

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {
    [Settings loadSettings];

    [self refreshMenu];

    // Move this task to prefpane instead. Starting at Sierra
    //[self addJitouchToLoginItems];

    cursorWindow = [[CursorWindow alloc] init];

    //languageChanged(NULL, NULL, NULL, NULL, NULL);

    gesture = [[Gesture alloc] init];

    //[self showIcon];

    [self checkAXAPI];

    [[NSDistributedNotificationCenter defaultCenter] addObserver: self
                                                        selector: @selector(settingsUpdated:)
                                                            name: @"My Notification"
                                                          object: @"com.jitouch.Jitouch.PrefpaneTarget"];

    [[[NSWorkspace sharedWorkspace] notificationCenter] addObserver:self selector:@selector(wokeUp:) name:NSWorkspaceDidWakeNotification object: NULL];

    //CFNotificationCenterAddObserver(CFNotificationCenterGetDistributedCenter(), self, languageChanged, kTISNotifySelectedKeyboardInputSourceChanged, NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
}

- (void)wokeUp:(NSNotification *)aNotification {
    NSLog(@"Woke up.");
    [self reload];
}

- (void)reload {
    [gesture reload];
}

#pragma mark -

- (void) dealloc {
    [cursorWindow release];
    [super dealloc];
}

@end
