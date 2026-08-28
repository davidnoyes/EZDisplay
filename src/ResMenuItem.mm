//
//  ResMenuItem.mm
//

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>

#import "ResMenuItem.h"
#import "utils.h"

/// Orders two numbers largest-first, which is the order every field in
/// `compareResMenuItem:` wants.
static NSComparisonResult LargestFirst(float mine, float theirs)
{
    if (mine > theirs)
        return NSOrderedAscending;
    if (mine < theirs)
        return NSOrderedDescending;

    return NSOrderedSame;
}


@implementation ResMenuItem

- (instancetype) initWithDisplay: (CGDirectDisplayID) display
                         andMode: (const DisplayModeDescription *) mode
{
    if (display == kCGNullDirectDisplay || mode == NULL)
        return nil;

    self = [super initWithTitle: @"" action: @selector(setMode:) keyEquivalent: @""];
    if (self == nil)
        return nil;

    _display     = display;
    _modeNum     = mode->number;
    _width       = mode->width;
    _height      = mode->height;
    _refreshRate = mode->refreshRate;
    _scale       = mode->scale;

    [self applyResolutionTitle: NO];

    return self;
}


// NSMenuItem's copy allocates an instance of the receiver's class but knows
// nothing about the fields added here, so they are carried over by hand.
- (id) copyWithZone: (NSZone *) zone
{
    ResMenuItem *copy = [super copyWithZone: zone];

    copy->_display     = _display;
    copy->_modeNum     = _modeNum;
    copy->_width       = _width;
    copy->_height      = _height;
    copy->_refreshRate = _refreshRate;
    copy->_scale       = _scale;

    return copy;
}


- (void) applyResolutionTitle: (BOOL) retinaTag
{
    NSString *size = [NSString stringWithFormat: @"%d × %d", _width, _height];

    self.title = (retinaTag && self.isHiDPI)
        ? [size stringByAppendingString: @"    Retina"]
        : size;
}


- (void) applyRefreshRateTitle
{
    self.title = [NSString stringWithFormat: @"%d Hz", _refreshRate];
}


- (BOOL) isHiDPI
{
    return _scale >= 2.0f;
}


- (float) aspectRatio
{
    if (_height <= 0)
        return 0.0f;

    return (float) _width / (float) _height;
}


- (BOOL) isResolutionW: (int) w height: (int) h scale: (float) s
{
    return _width == w && _height == h && _scale == s;
}


- (NSComparisonResult) compareResMenuItem: (ResMenuItem *) otherItem
{
    NSComparisonResult order = LargestFirst(_width, otherItem.width);
    if (order != NSOrderedSame)
        return order;

    order = LargestFirst(_scale, otherItem.scale);
    if (order != NSOrderedSame)
        return order;

    order = LargestFirst(_height, otherItem.height);
    if (order != NSOrderedSame)
        return order;

    return LargestFirst(_refreshRate, otherItem.refreshRate);
}

@end
