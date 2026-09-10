//
//  bridging-tests.h
//
//  What the Swift side of the test target can see of the Objective-C++ side.
//
//  Deliberately not src/bridging.h. That header reaches seven others, and the
//  test target links the implementations of only some of them — so a test that
//  used one of the rest would type-check and then fail at link time, which is a
//  much worse error to read than a missing import. This header names only what
//  the target can actually link.
//

#pragma once

#import "../src/Update.h"
