//
//  bridging.h
//
//  What the Swift side of the app can see of the Objective-C++ side.
//
//  Swift reaches the display and colour-mode code through this one header, so
//  anything a Swift file needs to call has to be reachable from here.
//

#pragma once

#import "ColorMode.h"
#import "CoreBrightness.h"
#import "DisplayModes.h"
#import "DisplayServices.h"
