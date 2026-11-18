#include "capture_clipboard.h"

#include <oleidl.h>
#include <shlobj.h>
#include <wincodec.h>
#include <wrl/client.h>

#include <cstring>
#include <utility>

#include "capture_util.h"

using Microsoft::WRL::ComPtr;

namespace {

// Larger images are not put on the clipboard (a DIB of 16384x16384).
constexpr uint64_t kMaxDibBytes = 1ull << 30;
// Larger GIF files are only offered as files, not as bytes.
constexpr uint64_t kMaxGifBytes = 1ull << 29;

// Owns a global memory block until the clipboard takes it.
class GlobalBlock {
 public:
  GlobalBlock() = default;
  explicit GlobalBlock(size_t size)
      : handle_(::GlobalAlloc(GMEM_MOVEABLE | GMEM_ZEROINIT, size)) {}
  ~GlobalBlock() { Free(); }
  GlobalBlock(GlobalBlock&& other) noexcept : handle_(other.release()) {}
  GlobalBlock& operator=(GlobalBlock&& other) noexcept {
    if (this != &other) {
      Free();
      handle_ = other.release();
    }
    return *this;
  }
  GlobalBlock(const GlobalBlock&) = delete;
  GlobalBlock& operator=(const GlobalBlock&) = delete;

  HGLOBAL get() const { return handle_; }
  // The clipboard owns the block after a successful SetClipboardData.
  HGLOBAL release() { return std::exchange(handle_, nullptr); }

 private:
  void Free() {
    if (handle_ != nullptr) {
      ::GlobalFree(handle_);
      handle_ = nullptr;
    }
  }

  HGLOBAL handle_ = nullptr;
};

// Another app may hold the clipboard for a moment.
bool OpenClipboardWithRetry(HWND owner) {
  for (int attempt = 0; attempt < 10; ++attempt) {
    if (::OpenClipboard(owner)) {
      return true;
    }
    ::Sleep(15);
  }
  return false;
}

// Opens and empties the clipboard, lets [fill] put the data on it (it returns
// whether that worked), and closes it again.
template <typename Fill>
bool ReplaceClipboard(HWND owner, Fill fill) {
  if (!OpenClipboardWithRetry(owner)) {
    return false;
  }
  bool done = false;
  if (::EmptyClipboard()) {
    done = fill();
  }
  ::CloseClipboard();
  return done;
}

// Hands [block] to the clipboard as [format]. The clipboard must be open.
bool SetData(UINT format, GlobalBlock& block) {
  if (format == 0 || block.get() == nullptr) {
    return false;
  }
  if (::SetClipboardData(format, block.get()) == nullptr) {
    return false;
  }
  block.release();
  return true;
}

GlobalBlock CopyToGlobal(const void* data, size_t size) {
  GlobalBlock block(size);
  if (block.get() != nullptr) {
    void* target = ::GlobalLock(block.get());
    if (target != nullptr) {
      std::memcpy(target, data, size);
      ::GlobalUnlock(block.get());
    }
  }
  return block;
}

// A PNG (or the first frame of a GIF) decoded into a CF_DIBV5 block:
// BITMAPV5HEADER, then bottom-up rows of 32-bit BGRA (straight alpha, the
// masks in the header).
bool MakeDibV5(const std::vector<uint8_t>& image, GlobalBlock* result) {
  ComPtr<IWICImagingFactory> factory;
  HRESULT hr = ::CoCreateInstance(CLSID_WICImagingFactory, nullptr,
                                  CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&factory));
  ComPtr<IWICStream> stream;
  if (SUCCEEDED(hr)) {
    hr = factory->CreateStream(&stream);
  }
  if (SUCCEEDED(hr)) {
    hr = stream->InitializeFromMemory(const_cast<BYTE*>(image.data()),
                                      static_cast<DWORD>(image.size()));
  }
  ComPtr<IWICBitmapDecoder> decoder;
  if (SUCCEEDED(hr)) {
    hr = factory->CreateDecoderFromStream(
        stream.Get(), nullptr, WICDecodeMetadataCacheOnDemand, &decoder);
  }
  ComPtr<IWICBitmapFrameDecode> frame;
  if (SUCCEEDED(hr)) {
    hr = decoder->GetFrame(0, &frame);
  }
  ComPtr<IWICFormatConverter> converter;
  if (SUCCEEDED(hr)) {
    hr = factory->CreateFormatConverter(&converter);
  }
  if (SUCCEEDED(hr)) {
    hr = converter->Initialize(frame.Get(), GUID_WICPixelFormat32bppBGRA,
                               WICBitmapDitherTypeNone, nullptr, 0.0,
                               WICBitmapPaletteTypeCustom);
  }
  UINT width = 0;
  UINT height = 0;
  if (SUCCEEDED(hr)) {
    hr = converter->GetSize(&width, &height);
  }
  if (FAILED(hr) || width == 0 || height == 0) {
    return false;
  }
  const uint64_t stride = static_cast<uint64_t>(width) * 4;
  const uint64_t pixels = stride * height;
  if (pixels > kMaxDibBytes) {
    return false;
  }
  GlobalBlock block(sizeof(BITMAPV5HEADER) + static_cast<size_t>(pixels));
  auto* base = static_cast<BYTE*>(
      block.get() == nullptr ? nullptr : ::GlobalLock(block.get()));
  if (base == nullptr) {
    return false;
  }
  auto* header = reinterpret_cast<BITMAPV5HEADER*>(base);
  header->bV5Size = sizeof(BITMAPV5HEADER);
  header->bV5Width = static_cast<LONG>(width);
  header->bV5Height = static_cast<LONG>(height);  // bottom-up
  header->bV5Planes = 1;
  header->bV5BitCount = 32;
  header->bV5Compression = BI_BITFIELDS;
  header->bV5SizeImage = static_cast<DWORD>(pixels);
  header->bV5RedMask = 0x00FF0000;
  header->bV5GreenMask = 0x0000FF00;
  header->bV5BlueMask = 0x000000FF;
  header->bV5AlphaMask = 0xFF000000;
  header->bV5CSType = LCS_sRGB;
  header->bV5Intent = LCS_GM_IMAGES;
  BYTE* rows = base + sizeof(BITMAPV5HEADER);
  for (UINT y = 0; y < height && SUCCEEDED(hr); ++y) {
    const WICRect line = {0, static_cast<INT>(y), static_cast<INT>(width), 1};
    hr = converter->CopyPixels(&line, static_cast<UINT>(stride),
                               static_cast<UINT>(stride),
                               rows + stride * (height - 1 - y));
  }
  ::GlobalUnlock(block.get());
  if (FAILED(hr)) {
    return false;
  }
  *result = std::move(block);
  return true;
}

// The paths that exist, made absolute. Empty ones are left out.
std::vector<std::wstring> ExistingFiles(
    const std::vector<std::wstring>& paths) {
  std::vector<std::wstring> files;
  for (const auto& path : paths) {
    if (path.empty()) {
      continue;
    }
    std::wstring full(MAX_PATH, L'\0');
    DWORD length = ::GetFullPathNameW(path.c_str(),
                                      static_cast<DWORD>(full.size()),
                                      full.data(), nullptr);
    if (length >= full.size()) {
      full.resize(length);
      length = ::GetFullPathNameW(path.c_str(), static_cast<DWORD>(full.size()),
                                  full.data(), nullptr);
    }
    if (length == 0 || length >= full.size()) {
      continue;
    }
    full.resize(length);
    if (::GetFileAttributesW(full.c_str()) == INVALID_FILE_ATTRIBUTES) {
      continue;
    }
    files.push_back(std::move(full));
  }
  return files;
}

// CF_HDROP of some files with "Preferred DropEffect" = copy.
class FileDrop {
 public:
  explicit FileDrop(const std::vector<std::wstring>& files) {
    const std::vector<uint8_t> drop = capture::BuildDropFiles(files);
    drop_ = CopyToGlobal(drop.data(), drop.size());
    const DWORD effect = DROPEFFECT_COPY;
    effect_ = CopyToGlobal(&effect, sizeof(effect));
  }

  bool ready() const { return drop_.get() != nullptr; }

  // Hands both to the open clipboard; true when CF_HDROP was taken.
  bool Set() {
    const bool done = SetData(CF_HDROP, drop_);
    SetData(::RegisterClipboardFormatW(CFSTR_PREFERREDDROPEFFECT), effect_);
    return done;
  }

 private:
  GlobalBlock drop_;
  GlobalBlock effect_;
};

// The whole file when it has 1 to [max_bytes] bytes.
bool ReadFileBytes(const std::wstring& path, uint64_t max_bytes,
                   std::vector<uint8_t>* out) {
  HANDLE file = ::CreateFileW(
      path.c_str(), GENERIC_READ,
      FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
      OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) {
    return false;
  }
  LARGE_INTEGER size = {};
  bool ok = ::GetFileSizeEx(file, &size) && size.QuadPart > 0 &&
            static_cast<uint64_t>(size.QuadPart) <= max_bytes;
  if (ok) {
    out->resize(static_cast<size_t>(size.QuadPart));
    DWORD read = 0;
    ok = ::ReadFile(file, out->data(), static_cast<DWORD>(out->size()), &read,
                    nullptr) &&
         read == out->size();
  }
  ::CloseHandle(file);
  return ok;
}

}  // namespace

bool CopyPngToClipboard(HWND owner, const std::vector<uint8_t>& png) {
  if (png.empty() || png.size() > MAXDWORD) {
    return false;
  }
  GlobalBlock dib;
  if (!MakeDibV5(png, &dib)) {
    return false;
  }
  GlobalBlock png_block = CopyToGlobal(png.data(), png.size());
  return ReplaceClipboard(owner, [&] {
    const bool done = SetData(CF_DIBV5, dib);
    // Apps that read PNG get the original bytes (and its exact colors).
    SetData(::RegisterClipboardFormatW(L"PNG"), png_block);
    return done;
  });
}

bool CopyFilesToClipboard(HWND owner, const std::vector<std::wstring>& paths) {
  const std::vector<std::wstring> files = ExistingFiles(paths);
  if (files.empty()) {
    return false;
  }
  FileDrop drop(files);
  if (!drop.ready()) {
    return false;
  }
  return ReplaceClipboard(owner, [&] { return drop.Set(); });
}

bool CopyGifToClipboard(HWND owner, const std::wstring& path) {
  const std::vector<std::wstring> files = ExistingFiles({path});
  if (files.empty()) {
    return false;
  }
  FileDrop drop(files);
  GlobalBlock gif_block;
  GlobalBlock dib;
  std::vector<uint8_t> gif;
  if (ReadFileBytes(files.front(), kMaxGifBytes, &gif)) {
    gif_block = CopyToGlobal(gif.data(), gif.size());
    MakeDibV5(gif, &dib);
  }
  return ReplaceClipboard(owner, [&] {
    // Listed first: apps that take the first format they know get the
    // animation, then the file, then a still of the first frame.
    bool done = SetData(::RegisterClipboardFormatW(L"GIF"), gif_block);
    done = drop.Set() || done;
    SetData(CF_DIBV5, dib);
    return done;
  });
}
