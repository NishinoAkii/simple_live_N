#include "process_launch.h"

#include <cstdio>

#include "capture_util.h"

namespace {

std::string Note(const char* what, DWORD error) {
  char text[96];
  std::snprintf(text, sizeof(text), "%s (error %lu)", what,
                static_cast<unsigned long>(error));
  return text;
}

// The token's user SID; empty when it cannot be read.
std::vector<BYTE> UserSid(HANDLE process) {
  std::vector<BYTE> user;
  HANDLE token = nullptr;
  if (!::OpenProcessToken(process, TOKEN_QUERY, &token)) {
    return user;
  }
  DWORD size = 0;
  ::GetTokenInformation(token, TokenUser, nullptr, 0, &size);
  std::vector<BYTE> buffer(size);
  if (size > 0 &&
      ::GetTokenInformation(token, TokenUser, buffer.data(), size, &size)) {
    const PSID sid = reinterpret_cast<TOKEN_USER*>(buffer.data())->User.Sid;
    const DWORD length = ::GetLengthSid(sid);
    const BYTE* bytes = static_cast<const BYTE*>(sid);
    user.assign(bytes, bytes + length);
  }
  ::CloseHandle(token);
  return user;
}

bool IsElevated() {
  HANDLE token = nullptr;
  if (!::OpenProcessToken(::GetCurrentProcess(), TOKEN_QUERY, &token)) {
    return false;
  }
  TOKEN_ELEVATION elevation = {};
  DWORD size = 0;
  const bool elevated =
      ::GetTokenInformation(token, TokenElevation, &elevation,
                            sizeof(elevation), &size) &&
      elevation.TokenIsElevated != 0;
  ::CloseHandle(token);
  return elevated;
}

// The desktop shell, opened for starting processes under it. A child of the
// shell gets the shell's token, so this is only done when that token is the
// same user's and we are not elevated (otherwise the window would run with
// other rights or another user's data).
HANDLE OpenShellProcess(std::string* note) {
  if (IsElevated()) {
    *note = "running elevated";
    return nullptr;
  }
  const HWND shell_window = ::GetShellWindow();
  DWORD shell_pid = 0;
  if (shell_window != nullptr) {
    ::GetWindowThreadProcessId(shell_window, &shell_pid);
  }
  if (shell_pid == 0) {
    *note = "no desktop shell";
    return nullptr;
  }
  HANDLE shell = ::OpenProcess(
      PROCESS_CREATE_PROCESS | PROCESS_QUERY_LIMITED_INFORMATION, FALSE,
      shell_pid);
  if (shell == nullptr) {
    *note = Note("desktop shell not accessible", ::GetLastError());
    return nullptr;
  }
  const std::vector<BYTE> ours = UserSid(::GetCurrentProcess());
  if (ours.empty() || ours != UserSid(shell)) {
    ::CloseHandle(shell);
    *note = "desktop shell runs as another user";
    return nullptr;
  }
  return shell;
}

std::wstring ImagePath(HANDLE process) {
  std::wstring path(MAX_PATH, L'\0');
  for (int attempt = 0; attempt < 3; ++attempt) {
    DWORD size = static_cast<DWORD>(path.size());
    if (::QueryFullProcessImageNameW(process, 0, path.data(), &size)) {
      path.resize(size);
      return path;
    }
    if (::GetLastError() != ERROR_INSUFFICIENT_BUFFER) {
      break;
    }
    path.resize(path.size() * 4);
  }
  return std::wstring();
}

}  // namespace

LaunchResult LaunchDetached(const std::wstring& program,
                            const std::vector<std::wstring>& arguments,
                            const std::wstring& directory) {
  LaunchResult result;
  const std::wstring command = capture::BuildCommandLine(program, arguments);
  // CreateProcess may write into the command line.
  std::vector<wchar_t> line;
  const auto reset_line = [&] {
    line.assign(command.begin(), command.end());
    line.push_back(L'\0');
  };
  // Same working directory and environment as a plain child would get.
  std::wstring folder = directory;
  if (folder.empty()) {
    const DWORD length = ::GetCurrentDirectoryW(0, nullptr);
    folder.resize(length);
    folder.resize(::GetCurrentDirectoryW(length, folder.data()));
  }
  const wchar_t* folder_ptr = folder.empty() ? nullptr : folder.c_str();
  LPWCH environment = ::GetEnvironmentStringsW();
  const DWORD flags = CREATE_UNICODE_ENVIRONMENT;
  PROCESS_INFORMATION info = {};

  HANDLE shell = OpenShellProcess(&result.note);
  if (shell != nullptr) {
    SIZE_T size = 0;
    ::InitializeProcThreadAttributeList(nullptr, 1, 0, &size);
    std::vector<BYTE> storage(size);
    auto* attributes =
        reinterpret_cast<LPPROC_THREAD_ATTRIBUTE_LIST>(storage.data());
    if (size > 0 &&
        ::InitializeProcThreadAttributeList(attributes, 1, 0, &size)) {
      if (::UpdateProcThreadAttribute(attributes, 0,
                                      PROC_THREAD_ATTRIBUTE_PARENT_PROCESS,
                                      &shell, sizeof(shell), nullptr,
                                      nullptr)) {
        STARTUPINFOEXW startup = {};
        startup.StartupInfo.cb = sizeof(startup);
        startup.lpAttributeList = attributes;
        reset_line();
        if (::CreateProcessW(program.c_str(), line.data(), nullptr, nullptr,
                             FALSE, flags | EXTENDED_STARTUPINFO_PRESENT,
                             environment, folder_ptr, &startup.StartupInfo,
                             &info)) {
          result.reparented = true;
        } else {
          result.note = Note("start under the shell failed", ::GetLastError());
        }
      } else {
        result.note = Note("parent attribute refused", ::GetLastError());
      }
      ::DeleteProcThreadAttributeList(attributes);
    } else {
      result.note = Note("no attribute list", ::GetLastError());
    }
    ::CloseHandle(shell);
  }

  if (!result.reparented) {
    STARTUPINFOW startup = {};
    startup.cb = sizeof(startup);
    reset_line();
    if (!::CreateProcessW(program.c_str(), line.data(), nullptr, nullptr,
                          FALSE, flags, environment, folder_ptr, &startup,
                          &info)) {
      result.note = Note("the window could not be started", ::GetLastError());
      if (environment != nullptr) {
        ::FreeEnvironmentStringsW(environment);
      }
      return result;
    }
  }
  if (environment != nullptr) {
    ::FreeEnvironmentStringsW(environment);
  }
  ::CloseHandle(info.hThread);
  result.process = info.hProcess;
  result.pid = info.dwProcessId;
  if (result.reparented) {
    result.note.clear();
  }
  return result;
}

bool IsSameExe(HANDLE process) {
  static const std::wstring ours = ImagePath(::GetCurrentProcess());
  const std::wstring theirs = ImagePath(process);
  return !ours.empty() && !theirs.empty() &&
         ::CompareStringOrdinal(theirs.c_str(), static_cast<int>(theirs.size()),
                                ours.c_str(), static_cast<int>(ours.size()),
                                TRUE) == CSTR_EQUAL;
}

bool TerminateIfSameExe(HANDLE process) {
  if (::GetProcessId(process) == ::GetCurrentProcessId() ||
      !IsSameExe(process)) {
    return false;
  }
  return ::TerminateProcess(process, 1) != FALSE;
}
