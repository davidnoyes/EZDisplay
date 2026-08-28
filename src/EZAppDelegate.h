//
//  EZAppDelegate.h
//
//  The application delegate. It owns the status-bar item and rebuilds the menu
//  hanging off it whenever the set of displays, or their settings, change.
//
//  The state behind all of that is private, so it lives with the
//  implementation rather than here.
//

#pragma once

#import <AppKit/AppKit.h>

@interface EZAppDelegate : NSObject <NSApplicationDelegate, NSMenuDelegate>

/// Rebuilds the status-bar menu from the displays attached right now.
- (void) refreshStatusMenu;

/// Brings up the preferences window, creating it the first time.
- (void) showPreferences;

@end
