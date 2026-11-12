//
//  JitouchPref.m
//  Jitouch
//
//  Copyright 2021 Supasorn Suwajanakorn and Sukolsak Sakshuwong. All rights reserved.
//  Modified work Copyright 2021 Aaron Kollasch. All rights reserved.
//

#import "JitouchPref.h"
#import "KeyTextField.h"
#import "KeyTextView.h"
#import "Settings.h"
#import "TrackpadTab.h"
#import "MagicMouseTab.h"
#import "RecognitionTab.h"
#import <Carbon/Carbon.h>

@implementation JitouchPref

CFMachPortRef eventTap;

#ifdef DEBUG
- (void)redirectLog
{
    NSString *pathForLog = [@"~/Library/Logs/com.jitouch.Jitouch.prefpane.log" stringByStandardizingPath];
    freopen([pathForLog cStringUsingEncoding:NSASCIIStringEncoding],"a+",stderr);
    NSLog(@"Jitouch prefPane opened");
}
#else
- (void)redirectLog
{
    return;
}
#endif

- (void)enUpdated {
    [trackpadTab enUpdated];
    [magicMouseTab enUpdated];
    [recognitionTab enUpdated];
    if (enAll) {
        [sdClickSpeed setEnabled:YES];
        [sdSensitivity setEnabled:YES];
    } else {
        [sdClickSpeed setEnabled:NO];
        [sdSensitivity setEnabled:NO];
    }
}

- (IBAction)change:(id)sender {
    if (sender == scAll) {
        int value = (int)[sender selectedSegment];
        enAll = value;
        [Settings setKey:@"enAll" withInt:value];

        [self enUpdated];
        if (enAll) {
            [self ensureJitouchRunning];
        }
    } else if (sender == cbShowIcon) {
        int value = [sender state] == NSControlStateValueOn ? 1: 0;
        [Settings setKey:@"ShowIcon" withInt:value];
    } else if (sender == sdClickSpeed) {
        clickSpeed = 0.5 - [sender floatValue];
        [Settings setKey:@"ClickSpeed" withFloat:0.5 - [sender floatValue]];
    } else if (sender == sdSensitivity) {
        stvt = [sender floatValue];
        [Settings setKey:@"Sensitivity" withFloat:[sender floatValue]];
    } else if (sender == loggingMode) {
        logLevel = (int)[sender selectedTag];
        [Settings setKey:@"LogLevel" withInt:(int)[[sender selectedItem] tag]];
    }
    [Settings noteSettingsUpdated];
}

- (id)windowWillReturnFieldEditor:(NSWindow *)sender toObject:(id)anObject {
    if ([anObject isKindOfClass:[KeyTextField class]]) {
        if (!keyTextView) {
            keyTextView = [[KeyTextView alloc] init];
            [keyTextView setFieldEditor:YES];
        }
        return keyTextView;
    }
    return nil;
}

#pragma mark -

- (BOOL)jitouchIsRunning {
    NSArray *apps = [[NSWorkspace sharedWorkspace] runningApplications];
    for (NSRunningApplication *app in apps) {
        if ([app.bundleIdentifier isEqualToString:@"com.jitouch.Jitouch"])
            return YES;
    }
    return NO;
}

- (void)settingsUpdated:(NSNotification *)aNotification {
    NSDictionary *d = [aNotification userInfo];
    [Settings readSettings2:d];

    [scAll setSelectedSegment:enAll];
    [self enUpdated];
}


- (void)killAllJitouchs {
    NSString *script = @"killall Jitouch";
    NSArray *shArgs = [NSArray arrayWithObjects:@"-c", script, @"", nil];
    [NSTask launchedTaskWithLaunchPath:@"/bin/sh" arguments:shArgs];
}


static CGEventRef CGEventCallback(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *refcon) {
    if ([NSApp isActive] && [[[NSApp keyWindow] firstResponder] isKindOfClass:[KeyTextView class]]) {
        if (type == kCGEventKeyDown) {
            int64_t keyCode = CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);
            CGEventFlags flags = CGEventGetFlags(event);
            [(KeyTextView*)[[NSApp keyWindow] firstResponder] handleEventKeyCode:keyCode flags:flags];
            return NULL;
        } else if (type == kCGEventKeyUp) {
            return NULL;
        }
    }
    return event;
}

// Jitouch.app registers its own launch agent through SMAppService. The pane only
// has to make sure the app is running; registration happens on the app's side
// because SMAppService resolves the bundle of the calling process, which here is
// System Settings.
- (NSURL *)jitouchAppURL {
    return [[[self bundle] bundleURL] URLByAppendingPathComponent:@"Contents/Resources/Jitouch.app"];
}

// Previous releases installed ~/Library/LaunchAgents/com.jitouch.Jitouch.plist.
// Stop that job and drop the file once, otherwise it would launch a second job
// with the same label as the SMAppService one.
- (BOOL)removeLegacyLaunchAgent {
    NSString *plistPath = [@"~/Library/LaunchAgents/com.jitouch.Jitouch.plist" stringByExpandingTildeInPath];
    if (![[NSFileManager defaultManager] fileExistsAtPath:plistPath]) {
        return NO;
    }
    NSString *job = [NSString stringWithFormat:@"gui/%d/com.jitouch.Jitouch.agent", getuid()];
    NSTask *bootout = [NSTask launchedTaskWithLaunchPath:@"/bin/launchctl"
                                               arguments:[NSArray arrayWithObjects:@"bootout", job, nil]];
    [bootout waitUntilExit];
    // bootout only signals the job; give the old process a moment to go away so the
    // relaunch below starts one instance instead of racing a dying one.
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:3.0];
    while ([self jitouchIsRunning] && [deadline timeIntervalSinceNow] > 0.0) {
        [NSThread sleepForTimeInterval:0.1];
    }
    [[NSFileManager defaultManager] removeItemAtPath:plistPath error:NULL];
    return YES;
}

- (void)ensureJitouchRunning {
    BOOL stoppedLegacyAgent = [self removeLegacyLaunchAgent];
    if (!stoppedLegacyAgent && [self jitouchIsRunning]) {
        return;
    }
    // Jitouch.app takes over from here: it registers the launch agent and exits, and
    // launchd runs the registered instance.
    NSWorkspaceOpenConfiguration *configuration = [NSWorkspaceOpenConfiguration configuration];
    configuration.createsNewApplicationInstance = YES;
    [[NSWorkspace sharedWorkspace] openApplicationAtURL:[self jitouchAppURL]
                                          configuration:configuration
                                      completionHandler:nil];
}

- (void)mainViewDidLoad {
    [self redirectLog];
    isPrefPane = YES;
    [Settings loadSettings:self];

    [scAll setSelectedSegment:enAll];
    [cbShowIcon setState:[[settings objectForKey:@"ShowIcon"] intValue]];
    [sdClickSpeed setFloatValue:0.5-clickSpeed];
    [sdSensitivity setFloatValue:stvt];
    [loggingMode selectItemWithTag:logLevel];

    [self enUpdated];

    [[NSDistributedNotificationCenter defaultCenter] addObserver: self
                                                        selector: @selector(settingsUpdated:)
                                                            name: @"My Notification2"
                                                          object: @"com.jitouch.Jitouch.PrefpaneTarget2"];


    BOOL running = [self jitouchIsRunning];
    if (running && hasPreviousVersion) {
        [self killAllJitouchs];
        running = NO;
    }
    [self ensureJitouchRunning];


    NSInteger tabIndex;
    if ([settings objectForKey:@"LastTab"] && (tabIndex=[mainTabView indexOfTabViewItemWithIdentifier:[settings objectForKey:@"LastTab"]]) != NSNotFound) {
        [mainTabView selectTabViewItemAtIndex:tabIndex];
    } else {
        CFMutableDictionaryRef matchingDict = IOServiceNameMatching("AppleUSBMultitouchDriver");
        io_registry_entry_t service = (io_registry_entry_t)IOServiceGetMatchingService(kIOMasterPortDefault, matchingDict);
        if (service) {
            [mainTabView selectTabViewItemWithIdentifier:@"Trackpad"];
        } else {
            [mainTabView selectTabViewItemWithIdentifier:@"Magic Mouse"];
        }
    }

    mainView = [self mainView];

}

- (BOOL)jitouchHasAccessibilityPermission {
    Boolean trusted = false;
    CFPropertyListRef value = CFPreferencesCopyAppValue(CFSTR("axTrusted"), appID);
    if (value) {
        int flag = 0;
        if (CFGetTypeID(value) == CFNumberGetTypeID() &&
            CFNumberGetValue((CFNumberRef)value, kCFNumberIntType, &flag)) {
            trusted = (flag != 0);
        }
        CFRelease(value);
    }
    return trusted;
}

- (void)showPermissionGuidanceIfNeeded {
    static BOOL guidanceShown = NO;
    // Only speak up when Jitouch is actually running and reports itself as
    // untrusted; a stale preference while the agent is stopped is not a
    // permission problem.
    if (guidanceShown || ![self jitouchIsRunning] || [self jitouchHasAccessibilityPermission]) {
        return;
    }
    guidanceShown = YES;

    NSAlert *alert = [[NSAlert alloc] init];
    [alert setMessageText:@"Jitouch has no Accessibility permission"];
    [alert setInformativeText:
        @"Gestures stay inactive until Jitouch is allowed to control the computer.\n\n"
        @"In System Settings › Privacy & Security turn Jitouch on under\n"
        @"• “Device Control and Data Access” (macOS 26 and later), or\n"
        @"• “Accessibility” (macOS 15 and earlier).\n\n"
        @"Jitouch notices the change by itself — switching back here afterwards is enough."];
    [alert setAlertStyle:NSAlertStyleWarning];
    [alert addButtonWithTitle:@"Open System Settings"];
    [alert addButtonWithTitle:@"Later"];

    NSWindow *window = [[self mainView] window];
    if (window) {
        [alert beginSheetModalForWindow:window completionHandler:^(NSModalResponse response) {
            if (response == NSAlertFirstButtonReturn) {
                AXIsProcessTrustedWithOptions((CFDictionaryRef)@{(id)kAXTrustedCheckOptionPrompt: @(YES)});
                NSURL *url = [NSURL URLWithString:@"x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility"];
                if (url) {
                    [[NSWorkspace sharedWorkspace] openURL:url];
                }
            }
        }];
    } else {
        if ([alert runModal] == NSAlertFirstButtonReturn) {
            AXIsProcessTrustedWithOptions((CFDictionaryRef)@{(id)kAXTrustedCheckOptionPrompt: @(YES)});
        }
    }
    [alert release];
}

- (void)willSelect {
    // The pane used to ask for the host app's permission on every visit, which is
    // why the "asking for permissions" prompt kept reappearing (issue #83).
    static BOOL promptedForHostPermission = NO;
    BOOL trusted = AXIsProcessTrusted();
    if (!trusted && !promptedForHostPermission) {
        promptedForHostPermission = YES;
        AXIsProcessTrustedWithOptions((CFDictionaryRef)@{(id)kAXTrustedCheckOptionPrompt: @(YES)});
    }

    if (trusted && !eventKeyboard) {
        CGEventMask eventMask = CGEventMaskBit(kCGEventKeyDown) | CGEventMaskBit(kCGEventKeyUp);
        eventKeyboard = CGEventTapCreate(kCGSessionEventTap, kCGHeadInsertEventTap, 0, eventMask, CGEventCallback, NULL);

        CGEventTapEnable(eventKeyboard, false);
        CFRunLoopSourceRef runLoopSource = CFMachPortCreateRunLoopSource( kCFAllocatorDefault, eventKeyboard, 0);
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, kCFRunLoopCommonModes);
    }

    [self showPermissionGuidanceIfNeeded];
}

- (void)willUnselect {
    [trackpadTab willUnselect];
    [magicMouseTab willUnselect];
    [recognitionTab willUnselect];
}

- (void)tabView:(NSTabView *)tabView didSelectTabViewItem:(NSTabViewItem *)tabViewItem {
    [Settings setKey:@"LastTab" with:[tabViewItem identifier]];
    [settings setObject:[tabViewItem identifier] forKey:@"LastTab"];
}

@end
