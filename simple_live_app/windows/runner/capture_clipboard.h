#ifndef RUNNER_CAPTURE_CLIPBOARD_H_
#define RUNNER_CAPTURE_CLIPBOARD_H_

#include <windows.h>

#include <cstdint>
#include <string>
#include <vector>

// Puts a PNG image on the clipboard as CF_DIBV5 (32-bit with alpha) and as
// the registered "PNG" format (the bytes as given). [owner] becomes the
// clipboard owner. Call on a thread with COM initialized.
bool CopyPngToClipboard(HWND owner, const std::vector<uint8_t>& png);

// Puts files on the clipboard as CF_HDROP with "Preferred DropEffect" = copy,
// so pasting in Explorer or a chat app copies them. Paths that do not exist
// are left out; false when none is left.
bool CopyFilesToClipboard(HWND owner, const std::vector<std::wstring>& paths);

// Puts a GIF file on the clipboard so apps can paste the animation: the
// registered "GIF" format (the file's bytes), the file itself as
// CopyFilesToClipboard does, and CF_DIBV5 of the first frame for apps that
// only take still images. False when the file does not exist. Call on a
// thread with COM initialized.
bool CopyGifToClipboard(HWND owner, const std::wstring& path);

#endif  // RUNNER_CAPTURE_CLIPBOARD_H_
