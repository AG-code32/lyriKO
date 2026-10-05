#include "flutter_window.h"

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <windows.h>
#include <mmdeviceapi.h>
#include <audioclient.h>
#include <wrl/client.h>

#include <chrono>
#include <cstdint>
#include <cstring>
#include <fstream>
#include <optional>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

#include "flutter/generated_plugin_registrant.h"
#include "media_session_bridge.h"

using Microsoft::WRL::ComPtr;

namespace {

void WriteUint32(
    std::ofstream& file,
    uint32_t value) {
  file.write(
      reinterpret_cast<const char*>(
          &value),
      sizeof(value));
}

bool WriteWaveFile(
    const std::wstring& path,
    const std::vector<uint8_t>& format,
    const std::vector<uint8_t>& audio) {
  if (format.empty()) {
    return false;
  }

  std::ofstream file(
      path,
      std::ios::binary);

  if (!file.is_open()) {
    return false;
  }

  const uint32_t fmt_size =
      static_cast<uint32_t>(
          format.size());

  const uint32_t data_size =
      static_cast<uint32_t>(
          audio.size());

  const uint32_t riff_size =
      4 +
      8 + fmt_size +
      8 + data_size;

  file.write("RIFF", 4);
  WriteUint32(
      file,
      riff_size);

  file.write("WAVE", 4);

  file.write("fmt ", 4);
  WriteUint32(
      file,
      fmt_size);

  file.write(
      reinterpret_cast<const char*>(
          format.data()),
      format.size());

  file.write("data", 4);
  WriteUint32(
      file,
      data_size);

  if (!audio.empty()) {
    file.write(
        reinterpret_cast<const char*>(
            audio.data()),
        audio.size());
  }

  return file.good();
}

std::wstring CreateSnapshotPath() {
  wchar_t temp_path[MAX_PATH];

  const DWORD length =
      GetTempPathW(
          MAX_PATH,
          temp_path);

  if (length == 0 ||
      length >= MAX_PATH) {
    return L"fingerprint_snapshot.wav";
  }

  const auto now =
      std::chrono::
          high_resolution_clock::
              now()
          .time_since_epoch()
          .count();

  std::wstring path(
      temp_path);

  path +=
      L"fingerprint_snapshot_";

  path +=
      std::to_wstring(
          now);

  path += L".wav";

  return path;
}

std::string WideToUtf8(
    const std::wstring& text) {
  if (text.empty()) {
    return {};
  }

  const int required =
      WideCharToMultiByte(
          CP_UTF8,
          0,
          text.c_str(),
          static_cast<int>(
              text.size()),
          nullptr,
          0,
          nullptr,
          nullptr);

  std::string output(
      required,
      '\0');

  WideCharToMultiByte(
      CP_UTF8,
      0,
      text.c_str(),
      static_cast<int>(
          text.size()),
      output.data(),
      required,
      nullptr,
      nullptr);

  return output;
}

}  // namespace

FlutterWindow::FlutterWindow(
    const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {
  StopContinuousCapture();
}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame =
      GetClientArea();

  flutter_controller_ =
      std::make_unique<
          flutter::
              FlutterViewController>(
          frame.right -
              frame.left,
          frame.bottom -
              frame.top,
          project_);

  if (!flutter_controller_
           ->engine() ||
      !flutter_controller_
           ->view()) {
    return false;
  }

  RegisterPlugins(
      flutter_controller_
          ->engine());

  RegisterMediaSessionBridge(
      flutter_controller_
          ->engine()
          ->messenger());

  system_audio_channel_ =
      std::make_unique<
          flutter::
              MethodChannel<
                  flutter::
                      EncodableValue>>(
          flutter_controller_
              ->engine()
              ->messenger(),
          "lyrics_app/system_audio",
          &flutter::
              StandardMethodCodec::
                  GetInstance());

  system_audio_channel_
      ->SetMethodCallHandler(
          [this](
              const flutter::
                  MethodCall<
                      flutter::
                          EncodableValue>&
                  call,
              std::unique_ptr<
                  flutter::
                      MethodResult<
                          flutter::
                              EncodableValue>>
                  result) {
            const auto&
                method =
                    call.method_name();

            if (method ==
                "startContinuousCapture") {
              try {
                StartContinuousCapture();

                result->Success();
              } catch (
                  const std::
                      exception& e) {
                result->Error(
                    "CAPTURE_START_ERROR",
                    e.what());
              }

              return;
            }

            if (method ==
                "snapshotContinuousCapture") {
              try {
                int duration_ms = 2000;

                const auto* arguments =
                    std::get_if<
                        flutter::EncodableMap>(
                        call.arguments());

                if (arguments != nullptr) {
                  const auto iterator =
                      arguments->find(
                          flutter::EncodableValue(
                              "durationMs"));

                  if (iterator !=
                      arguments->end()) {
                    if (const auto* value =
                            std::get_if<int>(
                                &iterator->second)) {
                      duration_ms =
                          *value;
                    } else if (
                        const auto* value64 =
                            std::get_if<int64_t>(
                                &iterator->second)) {
                      duration_ms =
                          static_cast<int>(
                              *value64);
                    }
                  }
                }

                auto response =
                    CreateCaptureSnapshot(
                        duration_ms);

                result->Success(
                    flutter::EncodableValue(
                        response));
              } catch (
                  const std::
                      exception& e) {
                result->Error(
                    "CAPTURE_SNAPSHOT_ERROR",
                    e.what());
              }

              return;
            }

            if (method ==
                "stopContinuousCapture") {
              try {
                StopContinuousCapture();

                result->Success();
              } catch (
                  const std::
                      exception& e) {
                result->Error(
                    "CAPTURE_STOP_ERROR",
                    e.what());
              }

              return;
            }

            result->NotImplemented();
          });

  SetChildContent(
      flutter_controller_
          ->view()
          ->GetNativeWindow());

  flutter_controller_
      ->engine()
      ->SetNextFrameCallback(
          [this]() {
            this->Show();
          });

  flutter_controller_
      ->ForceRedraw();

  return true;
}

void FlutterWindow::
    StartContinuousCapture() {
  if (capture_active_
          .exchange(true)) {
    throw std::runtime_error(
        "System audio capture "
        "is already running.");
  }

  if (capture_thread_
          .joinable()) {
    capture_thread_.join();
  }

  capture_stop_requested_ =
      false;

  {
    std::lock_guard<std::mutex>
        lock(capture_mutex_);

    capture_audio_.clear();
    capture_format_.clear();

    capture_sample_rate_ = 0;
    capture_channels_ = 0;
    capture_bits_per_sample_ = 0;
    capture_avg_bytes_per_sec_ = 0;

    capture_error_.clear();
  }

  capture_thread_ =
      std::thread(
          [this]() {
            ContinuousCaptureLoop();
          });
}

void FlutterWindow::
    StopContinuousCapture() {
  capture_stop_requested_ =
      true;

  if (capture_thread_
          .joinable()) {
    capture_thread_.join();
  }

  capture_active_ =
      false;
}

void FlutterWindow::
    ContinuousCaptureLoop() {
  HRESULT hr =
      CoInitializeEx(
          nullptr,
          COINIT_MULTITHREADED);

  const bool
      should_uninitialize =
          SUCCEEDED(hr);

  auto set_error =
      [this](
          const std::string& error) {
        {
          std::lock_guard<std::mutex>
              lock(capture_mutex_);

          capture_error_ =
              error;
        }

        capture_active_ =
            false;
      };

  if (FAILED(hr) &&
      hr != RPC_E_CHANGED_MODE) {
    set_error(
        "CoInitializeEx failed.");

    return;
  }

  ComPtr<IMMDeviceEnumerator>
      enumerator;

  hr = CoCreateInstance(
      __uuidof(
          MMDeviceEnumerator),
      nullptr,
      CLSCTX_ALL,
      IID_PPV_ARGS(
          &enumerator));

  if (FAILED(hr)) {
    set_error(
        "Could not create "
        "audio device enumerator.");

    if (should_uninitialize) {
      CoUninitialize();
    }

    return;
  }

  ComPtr<IMMDevice>
      device;

  hr =
      enumerator
          ->GetDefaultAudioEndpoint(
              eRender,
              eConsole,
              &device);

  if (FAILED(hr)) {
    set_error(
        "Could not get default "
        "Windows output device.");

    if (should_uninitialize) {
      CoUninitialize();
    }

    return;
  }

  ComPtr<IAudioClient>
      audio_client;

  hr = device->Activate(
      __uuidof(IAudioClient),
      CLSCTX_ALL,
      nullptr,
      &audio_client);

  if (FAILED(hr)) {
    set_error(
        "Could not activate "
        "WASAPI audio client.");

    if (should_uninitialize) {
      CoUninitialize();
    }

    return;
  }

  WAVEFORMATEX*
      mix_format = nullptr;

  hr =
      audio_client
          ->GetMixFormat(
              &mix_format);

  if (FAILED(hr) ||
      mix_format == nullptr) {
    set_error(
        "Could not obtain "
        "Windows audio format.");

    if (should_uninitialize) {
      CoUninitialize();
    }

    return;
  }

  const size_t
      format_size =
          sizeof(WAVEFORMATEX) +
          mix_format->cbSize;

  {
    std::lock_guard<std::mutex>
        lock(capture_mutex_);

    capture_format_.resize(
        format_size);

    std::memcpy(
        capture_format_.data(),
        mix_format,
        format_size);

    capture_sample_rate_ =
        static_cast<int>(
            mix_format
                ->nSamplesPerSec);

    capture_channels_ =
        static_cast<int>(
            mix_format
                ->nChannels);

    capture_bits_per_sample_ =
        static_cast<int>(
            mix_format
                ->wBitsPerSample);

    capture_avg_bytes_per_sec_ =
        static_cast<int>(
            mix_format
                ->nAvgBytesPerSec);
  }

  constexpr REFERENCE_TIME
      buffer_duration =
          10000000;

  hr = audio_client->Initialize(
      AUDCLNT_SHAREMODE_SHARED,
      AUDCLNT_STREAMFLAGS_LOOPBACK,
      buffer_duration,
      0,
      mix_format,
      nullptr);

  if (FAILED(hr)) {
    CoTaskMemFree(
        mix_format);

    set_error(
        "WASAPI loopback "
        "initialization failed.");

    if (should_uninitialize) {
      CoUninitialize();
    }

    return;
  }

  ComPtr<IAudioCaptureClient>
      capture_client;

  hr =
      audio_client->GetService(
          IID_PPV_ARGS(
              &capture_client));

  if (FAILED(hr)) {
    CoTaskMemFree(
        mix_format);

    set_error(
        "Could not create "
        "WASAPI capture client.");

    if (should_uninitialize) {
      CoUninitialize();
    }

    return;
  }

  hr =
      audio_client->Start();

  if (FAILED(hr)) {
    CoTaskMemFree(
        mix_format);

    set_error(
        "Could not start "
        "system audio capture.");

    if (should_uninitialize) {
      CoUninitialize();
    }

    return;
  }

  while (
      !capture_stop_requested_) {
    UINT32 packet_length = 0;

    hr =
        capture_client
            ->GetNextPacketSize(
                &packet_length);

    if (FAILED(hr)) {
      set_error(
          "WASAPI packet read failed.");

      break;
    }

    while (packet_length != 0) {
      BYTE* data = nullptr;

      UINT32 frames = 0;

      DWORD flags = 0;

      hr =
          capture_client
              ->GetBuffer(
                  &data,
                  &frames,
                  &flags,
                  nullptr,
                  nullptr);

      if (FAILED(hr)) {
        set_error(
            "WASAPI GetBuffer failed.");

        break;
      }

      const size_t
          byte_count =
              static_cast<size_t>(
                  frames) *
              mix_format
                  ->nBlockAlign;

      {
        std::lock_guard<std::mutex>
            lock(capture_mutex_);

        const size_t
            old_size =
                capture_audio_
                    .size();

        capture_audio_
            .resize(
                old_size +
                byte_count);

        if ((flags &
             AUDCLNT_BUFFERFLAGS_SILENT) !=
            0) {
          std::memset(
              capture_audio_
                      .data() +
                  old_size,
              0,
              byte_count);
        } else if (
            data != nullptr) {
          std::memcpy(
              capture_audio_
                      .data() +
                  old_size,
              data,
              byte_count);
        }

        //
        // Rolling buffer:
        // keep only the latest 6 seconds.
        //
        if (capture_avg_bytes_per_sec_ >
            0) {
          const size_t max_bytes =
              static_cast<size_t>(
                  capture_avg_bytes_per_sec_) *
              6;

          if (capture_audio_.size() >
              max_bytes) {
            size_t remove_bytes =
                capture_audio_.size() -
                max_bytes;

            const size_t block_align =
                mix_format->nBlockAlign;

            if (block_align > 0) {
              remove_bytes -=
                  remove_bytes %
                  block_align;
            }

            if (remove_bytes > 0) {
              capture_audio_.erase(
                  capture_audio_.begin(),
                  capture_audio_.begin() +
                      remove_bytes);
            }
          }
        }
      }

      capture_client
          ->ReleaseBuffer(
              frames);

      hr =
          capture_client
              ->GetNextPacketSize(
                  &packet_length);

      if (FAILED(hr)) {
        packet_length = 0;
      }
    }

    std::this_thread::sleep_for(
        std::chrono::
            milliseconds(3));
  }

  audio_client->Stop();

  CoTaskMemFree(
      mix_format);

  if (should_uninitialize) {
    CoUninitialize();
  }

  capture_active_ =
      false;
}

flutter::EncodableMap
FlutterWindow::
    CreateCaptureSnapshot(
        int duration_ms) {
  std::vector<uint8_t>
      audio;

  std::vector<uint8_t>
      format;

  int sample_rate = 0;
  int channels = 0;
  int bits_per_sample = 0;
  int avg_bytes_per_sec = 0;

  std::string error;

  {
    std::lock_guard<std::mutex>
        lock(capture_mutex_);

    format =
        capture_format_;

    sample_rate =
        capture_sample_rate_;

    channels =
        capture_channels_;

    bits_per_sample =
        capture_bits_per_sample_;

    avg_bytes_per_sec =
        capture_avg_bytes_per_sec_;

    error =
        capture_error_;

    if (avg_bytes_per_sec > 0 &&
        !capture_audio_.empty()) {
      size_t requested_bytes =
          static_cast<size_t>(
              avg_bytes_per_sec) *
          static_cast<size_t>(
              duration_ms) /
          1000;

      if (requested_bytes >
          capture_audio_.size()) {
        requested_bytes =
            capture_audio_.size();
      }

      if (!format.empty()) {
        const auto* wave_format =
            reinterpret_cast<
                const WAVEFORMATEX*>(
                format.data());

        const size_t block_align =
            wave_format->nBlockAlign;

        if (block_align > 0) {
          requested_bytes -=
              requested_bytes %
              block_align;
        }
      }

      const size_t start =
          capture_audio_.size() -
          requested_bytes;

      audio.assign(
          capture_audio_.begin() +
              start,
          capture_audio_.end());
    }
  }

  if (!error.empty()) {
    throw std::runtime_error(
        error);
  }

  if (format.empty()) {
    throw std::runtime_error(
        "Audio capture has not "
        "initialized yet.");
  }

  if (audio.empty()) {
    throw std::runtime_error(
        "No system audio has "
        "been captured yet.");
  }

  const std::wstring path =
      CreateSnapshotPath();

  if (!WriteWaveFile(
          path,
          format,
          audio)) {
    throw std::runtime_error(
        "Could not write "
        "capture snapshot.");
  }

  double duration_seconds =
      0.0;

  if (avg_bytes_per_sec > 0) {
    duration_seconds =
        static_cast<double>(
            audio.size()) /
        static_cast<double>(
            avg_bytes_per_sec);
  }

  flutter::EncodableMap
      response;

  response[
      flutter::
          EncodableValue(
              "filePath")] =
      flutter::
          EncodableValue(
              WideToUtf8(path));

  response[
      flutter::
          EncodableValue(
              "bytes")] =
      flutter::
          EncodableValue(
              static_cast<int64_t>(
                  audio.size()));

  response[
      flutter::
          EncodableValue(
              "durationMs")] =
      flutter::
          EncodableValue(
              static_cast<int64_t>(
                  duration_seconds *
                  1000.0));

  response[
      flutter::
          EncodableValue(
              "sampleRate")] =
      flutter::
          EncodableValue(
              sample_rate);

  response[
      flutter::
          EncodableValue(
              "channels")] =
      flutter::
          EncodableValue(
              channels);

  response[
      flutter::
          EncodableValue(
              "bitsPerSample")] =
      flutter::
          EncodableValue(
              bits_per_sample);

  return response;
}

void FlutterWindow::OnDestroy() {
  StopContinuousCapture();

  if (flutter_controller_) {
    flutter_controller_ =
        nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT FlutterWindow::MessageHandler(
    HWND hwnd,
    UINT const message,
    WPARAM const wparam,
    LPARAM const lparam) noexcept {
  if (flutter_controller_) {
    std::optional<LRESULT>
        result =
            flutter_controller_
                ->HandleTopLevelWindowProc(
                    hwnd,
                    message,
                    wparam,
                    lparam);

    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      if (flutter_controller_) {
        flutter_controller_
            ->engine()
            ->ReloadSystemFonts();
      }
      break;
  }

  return Win32Window::
      MessageHandler(
          hwnd,
          message,
          wparam,
          lparam);
}