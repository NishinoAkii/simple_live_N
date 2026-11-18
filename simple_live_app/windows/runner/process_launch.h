#ifndef RUNNER_PROCESS_LAUNCH_H_
#define RUNNER_PROCESS_LAUNCH_H_

#include <windows.h>

#include <string>
#include <vector>

// Secondary window processes, started outside this process's tree.
//
// Windows records an app's sound by process tree (process loopback includes
// the target's child processes). A secondary window started as our child
// would be heard in the main window's recording, so it is started as a child
// of the desktop shell (explorer.exe) instead, with our environment and
// working directory.

struct LaunchResult {
  // The new process, owned by the caller; null when the start failed.
  HANDLE process = nullptr;
  DWORD pid = 0;
  // Started under the shell (false: a plain child of this process).
  bool reparented = false;
  // Why it is not reparented, or why the start failed.
  std::string note;
};

// Starts [program] with [arguments]. [directory] empty = our working
// directory. Falls back to a plain child process when the shell cannot be
// used (no shell, access denied, this process elevated or another user).
LaunchResult LaunchDetached(const std::wstring& program,
                            const std::vector<std::wstring>& arguments,
                            const std::wstring& directory);

// Whether [process] runs this same exe (guards against a reused pid).
// [process] needs PROCESS_QUERY_LIMITED_INFORMATION.
bool IsSameExe(HANDLE process);

// Ends [process] if it runs this same exe and is not this process.
// [process] needs PROCESS_TERMINATE and PROCESS_QUERY_LIMITED_INFORMATION.
bool TerminateIfSameExe(HANDLE process);

#endif  // RUNNER_PROCESS_LAUNCH_H_
