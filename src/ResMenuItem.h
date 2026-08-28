//
//  ResMenuItem.h
//
//  A menu item standing for one display mode.
//
//  The menu is rebuilt from scratch every time the displays change, and items
//  get copied between the curated list and the full one, so each item carries
//  everything needed to identify and apply its mode. Nothing here reads back
//  from the display.
//

#pragma once

#import <AppKit/AppKit.h>

#import "utils.h"

@interface ResMenuItem : NSMenuItem

/// Builds an item for one mode of one display. Returns nil if either is
/// missing, so a gap in the mode list cannot become an item that does nothing.
- (instancetype) initWithDisplay: (CGDirectDisplayID) display
                         andMode: (const DisplayModeDescription *) mode;

@property (readonly) CGDirectDisplayID display;
@property (readonly) int modeNum;
@property (readonly) int width;
@property (readonly) int height;
@property (readonly) int refreshRate;
@property (readonly) float scale;

/// Whether this mode renders at twice its reported size.
@property (readonly, getter=isHiDPI) BOOL hiDPI;

/// Width over height, or zero for a mode with no height to divide by.
@property (readonly) float aspectRatio;

/// Titles the item as a resolution, "1920 × 1080". Pass YES to add a trailing
/// "Retina" tag, which the curated list uses to mark its HiDPI rows.
- (void) applyResolutionTitle: (BOOL) retinaTag;

/// Titles the item as a refresh rate, "60 Hz".
- (void) applyRefreshRateTitle;

/// Whether this item stands for the given resolution. This is the one place
/// that decides "the display is currently showing this row".
- (BOOL) isResolutionW: (int) w height: (int) h scale: (float) s;

/// Orders items for display: widest first, then most scaled, then tallest,
/// then fastest.
- (NSComparisonResult) compareResMenuItem: (ResMenuItem *) otherItem;

@end
