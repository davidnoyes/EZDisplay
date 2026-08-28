//
//  cmdline.h
//
//  The command-line front end.
//

#pragma once

/// Runs the app as a command-line tool and returns the status the process
/// should exit with.
int RunCommandLine(int argc, char *const *argv);
