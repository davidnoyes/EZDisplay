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

    if (retinaTag && self.isHiDPI)
    {
        [self setTitle: size tagged: @"Retina"];
        return;
    }

    // An attributed title wins over a plain one, so it has to go for the plain
    // one to show at all. Reachable through copyWithZone:, which carries the
    // attributed title over with the rest of NSMenuItem's state.
    self.attributedTitle = nil;
    self.title           = size;
}


// Menus draw in a proportional font, so a tag padded out with spaces starts at
// a different x on every row: "1512 × 638" is visibly narrower than
// "2752 × 1152", and the tags step raggedly in and out. A tab stop puts them
// all in one column instead.
//
// The column has to clear the widest size string a display can produce. 100pt
// clears "5120 × 2880" comfortably at the menu font, and anything wider still
// lines up, because the default interval matches the stop and a long size
// simply carries its tag to the next multiple.
- (void) setTitle: (NSString *) size tagged: (NSString *) tag
{
    static const CGFloat tagColumn = 100.0;

    NSMutableParagraphStyle *style = [NSMutableParagraphStyle new];
    style.tabStops = @[[[NSTextTab alloc] initWithTextAlignment: NSTextAlignmentLeft
                                                       location: tagColumn
                                                        options: @{}]];
    style.defaultTabInterval = tagColumn;

    NSString *spaced = [NSString stringWithFormat: @"%@ %@", size, tag];

    // The plain title as well. It is not drawn — the attributed one wins — but
    // it is what type-select matches on. Set first, so the attributed title is
    // the one left in force.
    self.title = spaced;

    self.attributedTitle =
        [[NSAttributedString alloc] initWithString: [NSString stringWithFormat: @"%@\t%@", size, tag]
                                        attributes: @{ NSParagraphStyleAttributeName: style,
                                                       NSFontAttributeName: [NSFont menuFontOfSize: 0] }];

    // Measured: AppKit builds AXTitle from the attributed title and ignores the
    // plain one, so without this a screen reader is handed the tab character
    // that lines the tags up. Say it with a space instead.
    self.accessibilityTitle = spaced;
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
