//
//  DisplayModes.h
//  EZDisplay
//
//  Plain Objective-C bridge over the ObjC++ private-API mode enumeration in
//  utils.h, so Swift (the Preferences window) can list and apply display modes
//  without importing the C++ (extern "C") headers directly.
//

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

@interface EZDisplayMode : NSObject
@property (readonly) CGDirectDisplayID displayID;
@property (readonly) int   modeNum;
@property (readonly) int   width;
@property (readonly) int   height;
@property (readonly) float scale;        // 1.0, 2.0 …
@property (readonly) int   refreshRate;  // Hz (0 if unspecified)
@property (readonly) BOOL  isHiDPI;      // scale >= 2.0
@property (readonly) BOOL  isCurrent;    // the display's active mode
@end

@interface EZDisplayInfo : NSObject
@property (readonly) CGDirectDisplayID displayID;
@property (readonly, copy) NSString *name;
@property (readonly) int nativeWidth;    // native panel pixels (0 if unknown)
@property (readonly) int nativeHeight;
@property (readonly) int nativeRefresh;  // Hz (0 if unknown)
@end

@interface EZDisplays : NSObject
// Online displays, main display first.
+ (NSArray<EZDisplayInfo *> *)onlineDisplays;
// All modes for a display (includes duplicates from the private API).
+ (NSArray<EZDisplayMode *> *)modesForDisplay:(CGDirectDisplayID)display;
// Apply a mode; returns NO on CGError.
+ (BOOL)applyMode:(EZDisplayMode *)mode;
// Native panel resolution (pixels) and refresh. Returns NO if unknown.
+ (BOOL)getNativePixelWidth:(int *)width height:(int *)height refresh:(int *)refresh
                 forDisplay:(CGDirectDisplayID)display;
// Preferred localized name, falling back to a positional label ("Display 2").
+ (NSString *)nameForDisplay:(CGDirectDisplayID)display index:(int)index;
// The display's current mode number, and a raw apply — used by the
// confirm-or-revert flow to capture and restore a mode.
+ (int)currentModeNumForDisplay:(CGDirectDisplayID)display;
+ (BOOL)setModeNum:(int)modeNum forDisplay:(CGDirectDisplayID)display;
// Mirror every display to the main one, or release them all. Returns the
// CGError rather than a BOOL, because both callers name the failure they
// report. Reversible by calling it again with the old value, which is what
// makes it safe behind confirm-or-revert.
+ (CGError)setMirroring:(BOOL)on;
@end

NS_ASSUME_NONNULL_END
