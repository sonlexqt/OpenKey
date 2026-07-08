//
//  OpenKeyManager.h
//  ModernKey
//
//  Created by Tuyen on 1/27/19.
//  Copyright © 2019 Tuyen Mai. All rights reserved.
//

#ifndef OpenKeyManager_h
#define OpenKeyManager_h

#import <Cocoa/Cocoa.h>

typedef void (^CheckNewVersionCallback)(void);

// NSUserDefaults key holding the sound name played when switching input mode.
// Empty/absent means "use the system beep" (NSBeep), preserving legacy behavior.
extern NSString* const kSwitchSoundNameKey;

@interface OpenKeyManager : NSObject
+(BOOL)isInited;
+(BOOL)initEventTap;
+(BOOL)stopEventTap;

+(NSArray*)getTableCodes;

// Names of the built-in macOS sounds (e.g. Tink, Glass) available via NSSound.
+(NSArray<NSString*>*)getSystemSounds;

// Plays the currently-selected switch sound (reads kSwitchSoundNameKey, cached).
+(void)playSwitchSound;

// Plays a specific sound by name for UI preview; nil/empty falls back to NSBeep.
+(void)previewSound:(NSString*)soundName;

+(NSString*)getBuildDate;
+(void)showMessage:(NSWindow*)window message:(NSString*)msg subMsg:(NSString*)subMsg;

+(BOOL)quickConvert;

+(void)checkNewVersion:(NSWindow*)parent callbackFunc:(CheckNewVersionCallback) callback;

// Secure Input detection.
// While macOS "Secure Event Input" is enabled, the OS blocks ALL keyboard event
// taps, so OpenKey silently stops transforming keys (and the switch hotkey dies)
// even though the menu-bar toggle still flips vLanguage. These let the UI detect
// that state and tell the user which app is responsible.
+(BOOL)isSecureInputEnabled;

// Localized name of the app currently holding Secure Input (e.g. "Google Chrome"),
// or nil if Secure Input is off or the holder cannot be resolved.
+(NSString*)secureInputHolderName;
@end

#endif /* OpenKeyManager_h */
