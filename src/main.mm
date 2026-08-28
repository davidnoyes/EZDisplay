//
//  main.mm
//
//  Picks which of the app's two front ends to run.
//
//  Being handed any argument at all means someone is driving the app from a
//  shell, so that case runs the command line and exits without ever creating an
//  NSApplication. With no arguments the app puts up its status-bar menu instead.
//  Nothing in the command-line path may depend on AppKit, because none of it
//  exists there.
//

#import <AppKit/AppKit.h>

#import "EZAppDelegate.h"
#import "cmdline.h"

int main(int argc, char *argv[])
{
    if (argc > 1)
        return RunCommandLine(argc, argv);

    @autoreleasepool
    {
        NSApplication *app = [NSApplication sharedApplication];
        app.delegate = [EZAppDelegate new];
        [app run];
    }

    return 0;
}
