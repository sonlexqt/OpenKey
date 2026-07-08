//
//  OpenKeyManager.m
//  OpenKey
//
//  Created by Tuyen on 1/27/19.
//  Copyright © 2019 Tuyen Mai. All rights reserved.
//

#import "OpenKeyManager.h"
#import "AppDelegate.h"
#import <Carbon/Carbon.h>
#import <IOKit/IOKitLib.h>

// Generated on every build by Scripts/generate_buildinfo.sh (gitignored). Guarded
// so the file still compiles if the header is missing (e.g. IDE indexing before
// the first build); getBuildDate falls back to __DATE__ in that case.
#if __has_include("BuildInfo.h")
#import "BuildInfo.h"
#endif

// kIOMasterPortDefault was renamed kIOMainPortDefault (macOS 12). Fall back so
// the code builds against older SDKs / deployment targets too.
#ifndef kIOMainPortDefault
#define kIOMainPortDefault kIOMasterPortDefault
#endif

extern AppDelegate* appDelegate;

extern void OpenKeyInit(void);

extern CGEventRef OpenKeyCallback(CGEventTapProxy proxy,
                                  CGEventType type,
                                  CGEventRef event,
                                  void *refcon);

extern NSString* ConvertUtil(NSString* str);

@interface OpenKeyManager ()
+(void)playSound:(NSString*)name;
@end

@implementation OpenKeyManager {

}
static BOOL _isInited = NO;

// Not static: shared with OpenKey.mm (OpenKeyCallback) so the callback can re-enable
// the tap when macOS disables it (kCGEventTapDisabledByTimeout/ByUserInput).
CFMachPortRef             eventTap;
static CGEventMask        eventMask;
static CFRunLoopSourceRef runLoopSource;
static NSTimer*           watchdogTimer;

+(BOOL)isInited {
    return _isInited;
}

+(BOOL)initEventTap {
    if (_isInited)
        return true;
    
    //init modernKey
    OpenKeyInit();
    
    // Create an event tap. We are interested in key presses.
    eventMask = ((1 << kCGEventKeyDown) |
                 (1 << kCGEventKeyUp) |
                 (1 << kCGEventFlagsChanged) |
                 (1 << kCGEventLeftMouseDown) |
                 (1 << kCGEventRightMouseDown) |
                 (1 << kCGEventLeftMouseDragged) |
                 (1 << kCGEventRightMouseDragged));
    
    eventTap = CGEventTapCreate(kCGSessionEventTap,
                                kCGHeadInsertEventTap,
                                0,
                                eventMask,
                                OpenKeyCallback,
                                NULL);
    
    if (!eventTap) {
        
        fprintf(stderr, "failed to create event tap\n");
        return NO;
    }
    
    _isInited = YES;
    
    // Create a run loop source.
    runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0);
    
    // Add to the current run loop.
    CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, kCFRunLoopCommonModes);
    
    // Enable the event tap.
    CGEventTapEnable(eventTap, true);
    
    // Safety net: macOS can silently disable the tap without always notifying the callback
    // (e.g. under memory pressure / resource contention). Periodically re-enable if needed.
    watchdogTimer = [NSTimer scheduledTimerWithTimeInterval:5.0
                                                     target:self
                                                   selector:@selector(watchdogCheckEventTap:)
                                                   userInfo:nil
                                                    repeats:YES];
    
    return YES;
}

+(void)watchdogCheckEventTap:(NSTimer*)timer {
    if (eventTap && !CGEventTapIsEnabled(eventTap)) {
        CGEventTapEnable(eventTap, true);
    }
    // Secure Input can silently block the tap without disabling it; surface it.
    [appDelegate refreshSecureInputWarning];
}

+(BOOL)isSecureInputEnabled {
    return IsSecureEventInputEnabled() ? YES : NO;
}

// PID currently holding Secure Input, read from IOKit's console-users info.
// Returns 0 when Secure Input is off or the owner cannot be determined.
+(pid_t)secureInputPID {
    pid_t result = 0;
    io_registry_entry_t root = IORegistryGetRootEntry(kIOMainPortDefault);
    if (root == MACH_PORT_NULL)
        return 0;

    CFTypeRef prop = IORegistryEntrySearchCFProperty(root,
                                                     kIOServicePlane,
                                                     CFSTR("IOConsoleUsers"),
                                                     kCFAllocatorDefault,
                                                     kIORegistryIterateRecursively);
    IOObjectRelease(root);
    if (prop == NULL)
        return 0;

    if (CFGetTypeID(prop) == CFArrayGetTypeID()) {
        CFArrayRef users = (CFArrayRef)prop;
        for (CFIndex i = 0; i < CFArrayGetCount(users); i++) {
            CFDictionaryRef session = (CFDictionaryRef)CFArrayGetValueAtIndex(users, i);
            if (!session || CFGetTypeID(session) != CFDictionaryGetTypeID())
                continue;
            CFNumberRef pidRef = (CFNumberRef)CFDictionaryGetValue(session, CFSTR("kCGSSessionSecureInputPID"));
            if (pidRef && CFGetTypeID(pidRef) == CFNumberGetTypeID()) {
                int pid = 0;
                CFNumberGetValue(pidRef, kCFNumberIntType, &pid);
                if (pid > 0) {
                    result = (pid_t)pid;
                    break;
                }
            }
        }
    }
    CFRelease(prop);
    return result;
}

+(NSString*)secureInputHolderName {
    pid_t pid = [self secureInputPID];
    if (pid <= 0)
        return nil;
    NSRunningApplication* app = [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
    if (app.localizedName.length > 0)
        return app.localizedName;
    if (app.bundleIdentifier.length > 0)
        return app.bundleIdentifier;
    return nil;
}

+(BOOL)stopEventTap {
    if (_isInited) { //release all object
        [watchdogTimer invalidate];
        watchdogTimer = nil;
        
        CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, kCFRunLoopCommonModes);
        CFRelease(runLoopSource);
        runLoopSource = nil;
        
        CFMachPortInvalidate(eventTap);
        CFRelease(eventTap);
        eventTap = nil;
        
        _isInited = false;
    }
    return YES;
}

+(NSArray*)getTableCodes {
    return [[NSArray alloc] initWithObjects:
            @"Unicode",
            @"TCVN3 (ABC)",
            @"VNI Windows",
            @"Unicode tổ hợp",
            @"Vietnamese Locale CP 1258", nil];
}

#pragma mark -Switch sound feature

NSString* const kSwitchSoundNameKey = @"SwitchSoundName";

// Cache the resolved NSSound so switching modes never hits the disk.
static NSSound*  cachedSwitchSound = nil;
static NSString* cachedSwitchSoundName = nil;

+(NSArray<NSString*>*)getSystemSounds {
    // Enumerate the built-in macOS sounds so the list stays correct across OS versions.
    NSMutableArray<NSString*>* sounds = [NSMutableArray array];
    NSString* dir = @"/System/Library/Sounds";
    NSArray<NSString*>* files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:nil];
    for (NSString* file in [files sortedArrayUsingSelector:@selector(caseInsensitiveCompare:)]) {
        if ([[file.pathExtension lowercaseString] isEqualToString:@"aiff"]) {
            [sounds addObject:file.stringByDeletingPathExtension];
        }
    }
    if (sounds.count == 0) {
        // Fallback to the classic set if the directory could not be read.
        [sounds addObjectsFromArray:@[@"Basso", @"Blow", @"Bottle", @"Frog", @"Funk",
                                      @"Glass", @"Hero", @"Morse", @"Ping", @"Pop",
                                      @"Purr", @"Sosumi", @"Submarine", @"Tink"]];
    }
    return sounds;
}

+(void)playSwitchSound {
    NSString* name = [[NSUserDefaults standardUserDefaults] stringForKey:kSwitchSoundNameKey];
    [self playSound:name];
}

+(void)previewSound:(NSString*)soundName {
    [self playSound:soundName];
}

+(void)playSound:(NSString*)name {
    if (name == nil || name.length == 0) {
        NSBeep();
        return;
    }
    if (![name isEqualToString:cachedSwitchSoundName]) {
        cachedSwitchSound = [NSSound soundNamed:name];
        cachedSwitchSoundName = name;
    }
    if (cachedSwitchSound) {
        [cachedSwitchSound stop]; // restart cleanly on rapid consecutive switches
        [cachedSwitchSound play];
    } else {
        NSBeep();
    }
}

+(NSString*)getBuildDate {
#if defined(OPENKEY_BUILD_DATE) && defined(OPENKEY_GIT_COMMIT)
    return [NSString stringWithFormat:@"%s (%s)", OPENKEY_BUILD_DATE, OPENKEY_GIT_COMMIT];
#elif defined(OPENKEY_BUILD_DATE)
    return [NSString stringWithUTF8String:OPENKEY_BUILD_DATE];
#else
    // BuildInfo.h not generated yet; __DATE__ is the compile date of this file.
    return [NSString stringWithUTF8String:__DATE__];
#endif
}

#pragma mark -Convert feature
+(BOOL)quickConvert {
    NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
    NSString *htmlString = [pasteboard stringForType:NSPasteboardTypeHTML];
    NSString *rawString = [pasteboard stringForType:NSPasteboardTypeString];
    bool converted = false;
    if (htmlString != nil) {
        htmlString = ConvertUtil(htmlString);
        converted = true;
    }
    if (rawString != nil) {
        rawString = ConvertUtil(rawString);
        converted = true;
    }
    if (converted) {
        [pasteboard clearContents];
        if (htmlString != nil)
            [pasteboard setString:htmlString forType:NSPasteboardTypeHTML];
        if (rawString != nil)
            [pasteboard setString:rawString forType:NSPasteboardTypeString];
        
        return YES;
    }
    return NO;
}

+(void)showMessage:(NSWindow*)window message:(NSString*)msg subMsg:(NSString*)subMsg {
    NSAlert *alert = [[NSAlert alloc] init];
    [alert setMessageText:msg];
    [alert setInformativeText:subMsg];
    [alert addButtonWithTitle:@"OK"];
    if (window) {
        [alert beginSheetModalForWindow:window completionHandler:^(NSModalResponse returnCode) {
        }];
    } else {
        [alert runModal];
    }
}

#pragma mark -AutoUpdate feature

+(void)checkNewVersion:(NSWindow*)parent callbackFunc:(CheckNewVersionCallback) callback {
    //load new version config
    NSURLSession *aSession = [NSURLSession sessionWithConfiguration:[NSURLSessionConfiguration defaultSessionConfiguration]];
    [[aSession dataTaskWithURL:[NSURL URLWithString:@"https://raw.githubusercontent.com/tuyenvm/OpenKey/master/version.json"] completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (((NSHTTPURLResponse *)response).statusCode == 200) {
            if (data) {
                if(NSClassFromString(@"NSJSONSerialization")) {
                    NSError *error = nil;
                    id object = [NSJSONSerialization
                                 JSONObjectWithData:data
                                 options:0
                                 error:&error];
                    
                    if(error) {  }
                    if([object isKindOfClass:[NSDictionary class]]) {
                        NSDictionary *results = object;
                        NSDictionary *ver = [results valueForKey:@"latestVersion"];
                        NSString* versionCodeString = [ver valueForKey:@"versionCode"];
                        int versionCode = (int)[versionCodeString integerValue];
                        int currentVersionCode = (int)[((NSString*)[[NSBundle mainBundle] objectForInfoDictionaryKey: @"CFBundleVersion"]) integerValue];
                        
                        dispatch_async(dispatch_get_main_queue(), ^{
                            if (callback != nil) {
                                callback();
                            }
                            if (versionCode > currentVersionCode || callback != nil) {
                                [self showUpdateMessage:parent needUpdating:versionCode > currentVersionCode newVersion:[ver valueForKey:@"versionName"]];
                            }
                        });
                    }
                    else {
                        //oh my god
                    }
                }
                else {
                    //can not parse json
                }
            }
        }
    }] resume];
}

+(void)showUpdateMessage:(NSWindow*)parent needUpdating:(BOOL)needUpdating newVersion:(NSString*)versionString {
    NSAlert *alert = [[NSAlert alloc] init];
    [alert setMessageText:(needUpdating ? [NSString stringWithFormat:@"OpenKeyFix Có phiên bản mới (%@), bạn có muốn cập nhật không?", versionString] : @"Bạn đang dùng phiên bản mới nhất!")];
    [alert setInformativeText:(needUpdating ? @"Bấm 'Có' để cập nhật OpenKeyFix." : @"")];
    
    if (!needUpdating) {
        [alert addButtonWithTitle:@"OK"];
    } else {
        [alert addButtonWithTitle:@"Có"];
        [alert addButtonWithTitle:@"Không"];
    }
    if (parent == nil) {
        [alert.window makeKeyAndOrderFront:nil];
        [alert.window setLevel:NSStatusWindowLevel];
        NSModalResponse res = [alert runModal];
        if (res == 1000 && needUpdating) {
            [self launchUpdateHelper];
        }
    } else {
        [alert beginSheetModalForWindow:parent completionHandler:^(NSModalResponse returnCode) {
            if (returnCode == 1000 && needUpdating) {
                [self launchUpdateHelper];
            }
        }];
    }
}

+(void)launchUpdateHelper {
    //check update app has exist or not
    NSError *copyError = nil;
    NSString* target = [NSString stringWithFormat:@"%@/OpenKeyUpdate.app", [self getApplicationSupportFolder]];
    [[NSFileManager defaultManager] removeItemAtPath:target error:&copyError];
    if (![[NSFileManager defaultManager] fileExistsAtPath:target]) {
        [[NSFileManager defaultManager] createDirectoryAtPath:[self getApplicationSupportFolder] withIntermediateDirectories:YES attributes:nil error:nil];
        
        if (![[NSFileManager defaultManager] copyItemAtPath:[self getUpdateBundlePath] toPath:target error:&copyError]) {
            NSLog(@"Error on copy");
        }
    }
    
    NSWorkspace *workspace = [NSWorkspace sharedWorkspace];
    NSURL *url = [NSURL fileURLWithPath:[workspace fullPathForApplication:target]];
    NSError *error = nil;
    NSArray *arguments = [NSArray arrayWithObjects: @"yeah", nil];
    [workspace launchApplicationAtURL:url options:0 configuration:[NSDictionary dictionaryWithObject:arguments forKey:NSWorkspaceLaunchConfigurationArguments] error:&error];
    
    [NSApp terminate:0]; //exit main app
}

+(NSString*)getApplicationSupportFolder {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES);
    NSString *applicationSupportDirectory = [paths firstObject];
    return [NSString stringWithFormat:@"%@/OpenKey", applicationSupportDirectory];
}

+(NSString*)getUpdateBundlePath {
    NSString *currentpath = [[NSBundle mainBundle] bundlePath];
    return [NSString stringWithFormat:@"%@/Contents/Library/LoginItems/OpenKeyUpdate.app", currentpath];
}
@end
