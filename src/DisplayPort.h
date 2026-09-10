//
//  DisplayPort.h
//  EZDisplay
//
//  Which physical port a display is attached to, and whether a registry service
//  sits under it.
//
//  This is how a *monitor* is told from a model of monitor. Two of the same
//  display report the same vendor, product, and often the same serial, so
//  nothing in what they say about themselves separates them; the port they are
//  plugged into does. Color mode reached that conclusion first and DDC needs
//  the same answer, so the two share this rather than each parsing the registry
//  their own way.
//

#pragma once

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <IOKit/IOKitLib.h>

NS_ASSUME_NONNULL_BEGIN

/// The registry node naming the port `display` is attached to — `dispext0` for
/// the first external one, and the token the AV services for that port carry in
/// their own registry paths.
///
/// nil when CoreDisplay will not say, or when the location is not shaped the
/// way this expects: an Intel Mac, or a later macOS that renames these nodes.
/// A caller then has nothing to match on and has to fall back or fail closed.
///
/// Assumes one port means one monitor, which holds for a direct connection and
/// is the only case this has been tested against. Two identical displays behind
/// a DisplayPort MST hub would presumably share a port node.
NSString *_Nullable EZPortNodeForDisplay(CGDirectDisplayID display);

/// Whether `service` sits under `portNode`.
///
/// The trailing colon is required: without it `dispext1` also matches
/// `dispext10`.
BOOL EZServiceIsOnPort(io_service_t service, NSString *portNode);

NS_ASSUME_NONNULL_END
