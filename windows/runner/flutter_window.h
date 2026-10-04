#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/encodable_value.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>

#include <atomic>
#include <cstdint>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "win32_window.h"

class FlutterWindow : public Win32Window {
 public:
  explicit FlutterWindow(
      const flutter::DartProject& project);

  virtual ~FlutterWindow();

 protected:
  bool OnCreate() override;

  void OnDestroy() override;

  LRESULT MessageHandler(
      HWND window,
      UINT const message,
      WPARAM const wparam,
      LPARAM const lparam) noexcept override;

 private:
  void StartContinuousCapture();

  void StopContinuousCapture();

  void ContinuousCaptureLoop();

  flutter::EncodableMap
  CreateCaptureSnapshot(
      int duration_ms);

  flutter::DartProject project_;

  std::unique_ptr<
      flutter::FlutterViewController>
      flutter_controller_;

  std::unique_ptr<
      flutter::MethodChannel<
          flutter::EncodableValue>>
      system_audio_channel_;

  std::atomic<bool>
      capture_active_{false};

  std::atomic<bool>
      capture_stop_requested_{false};

  std::thread
      capture_thread_;

  std::mutex
      capture_mutex_;

  std::vector<uint8_t>
      capture_audio_;

  std::vector<uint8_t>
      capture_format_;

  int capture_sample_rate_ = 0;
  int capture_channels_ = 0;
  int capture_bits_per_sample_ = 0;
  int capture_avg_bytes_per_sec_ = 0;

  std::string
      capture_error_;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_