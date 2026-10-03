#include "flutter_window.h"

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <windows.h>
#include <mmdeviceapi.h>
#include <audioclient.h>
#include <wrl/client.h>

#include <chrono>
#include <cstdint>
#include <fstream>
#include <memory>
#include <string>
#include <thread>
#include <vector>

#include "flutter/generated_plugin_registrant.h"

using Microsoft::WRL::ComPtr;

namespace
{

  struct CaptureResult
  {
    std::wstring file_path;
    uint64_t audio_bytes = 0;
    int sample_rate = 0;
    int channels = 0;
    int bits_per_sample = 0;
  };

  void WriteUint16(
      std::ofstream &file,
      uint16_t value)
  {
    file.write(
        reinterpret_cast<const char *>(&value),
        sizeof(value));
  }

  void WriteUint32(
      std::ofstream &file,
      uint32_t value)
  {
    file.write(
        reinterpret_cast<const char *>(&value),
        sizeof(value));
  }

  bool WriteWaveFile(
      const std::wstring &path,
      const WAVEFORMATEX *format,
      const std::vector<BYTE> &audio_data)
  {
    std::ofstream file(
        path,
        std::ios::binary);

    if (!file.is_open())
    {
      return false;
    }

    const uint32_t fmt_size =
        sizeof(WAVEFORMATEX) + format->cbSize;

    const uint32_t data_size =
        static_cast<uint32_t>(
            audio_data.size());

    const uint32_t riff_size =
        4 +
        8 + fmt_size +
        8 + data_size;

    file.write("RIFF", 4);
    WriteUint32(file, riff_size);
    file.write("WAVE", 4);

    file.write("fmt ", 4);
    WriteUint32(file, fmt_size);

    file.write(
        reinterpret_cast<const char *>(format),
        fmt_size);

    file.write("data", 4);
    WriteUint32(file, data_size);

    if (!audio_data.empty())
    {
      file.write(
          reinterpret_cast<const char *>(
              audio_data.data()),
          audio_data.size());
    }

    return file.good();
  }

  std::wstring GetCapturePath()
  {
    wchar_t temp_path[MAX_PATH];

    const DWORD length =
        GetTempPathW(
            MAX_PATH,
            temp_path);

    if (length == 0 ||
        length > MAX_PATH)
    {
      return L"lyrics_system_capture.wav";
    }

    std::wstring path(temp_path);

    path += L"lyrics_system_capture.wav";

    return path;
  }

  CaptureResult CaptureSystemAudio(
      int duration_ms)
  {
    CaptureResult result;

    HRESULT hr =
        CoInitializeEx(
            nullptr,
            COINIT_MULTITHREADED);

    const bool should_uninitialize =
        SUCCEEDED(hr);

    if (FAILED(hr) &&
        hr != RPC_E_CHANGED_MODE)
    {
      throw std::runtime_error(
          "CoInitializeEx failed.");
    }

    ComPtr<IMMDeviceEnumerator> enumerator;

    hr = CoCreateInstance(
        __uuidof(MMDeviceEnumerator),
        nullptr,
        CLSCTX_ALL,
        IID_PPV_ARGS(&enumerator));

    if (FAILED(hr))
    {
      if (should_uninitialize)
      {
        CoUninitialize();
      }

      throw std::runtime_error(
          "Could not create audio device enumerator.");
    }

    ComPtr<IMMDevice> device;

    hr = enumerator->GetDefaultAudioEndpoint(
        eRender,
        eConsole,
        &device);

    if (FAILED(hr))
    {
      if (should_uninitialize)
      {
        CoUninitialize();
      }

      throw std::runtime_error(
          "Could not get default Windows output device.");
    }

    ComPtr<IAudioClient> audio_client;

    hr = device->Activate(
        __uuidof(IAudioClient),
        CLSCTX_ALL,
        nullptr,
        &audio_client);

    if (FAILED(hr))
    {
      if (should_uninitialize)
      {
        CoUninitialize();
      }

      throw std::runtime_error(
          "Could not activate WASAPI audio client.");
    }

    WAVEFORMATEX *mix_format = nullptr;

    hr = audio_client->GetMixFormat(
        &mix_format);

    if (FAILED(hr) ||
        mix_format == nullptr)
    {
      if (should_uninitialize)
      {
        CoUninitialize();
      }

      throw std::runtime_error(
          "Could not obtain Windows audio format.");
    }

    result.sample_rate =
        static_cast<int>(
            mix_format->nSamplesPerSec);

    result.channels =
        static_cast<int>(
            mix_format->nChannels);

    result.bits_per_sample =
        static_cast<int>(
            mix_format->wBitsPerSample);

    REFERENCE_TIME buffer_duration =
        10000000;

    hr = audio_client->Initialize(
        AUDCLNT_SHAREMODE_SHARED,
        AUDCLNT_STREAMFLAGS_LOOPBACK,
        buffer_duration,
        0,
        mix_format,
        nullptr);

    if (FAILED(hr))
    {
      CoTaskMemFree(mix_format);

      if (should_uninitialize)
      {
        CoUninitialize();
      }

      throw std::runtime_error(
          "WASAPI loopback initialization failed.");
    }

    ComPtr<IAudioCaptureClient>
        capture_client;

    hr = audio_client->GetService(
        IID_PPV_ARGS(&capture_client));

    if (FAILED(hr))
    {
      CoTaskMemFree(mix_format);

      if (should_uninitialize)
      {
        CoUninitialize();
      }

      throw std::runtime_error(
          "Could not create WASAPI capture client.");
    }

    hr = audio_client->Start();

    if (FAILED(hr))
    {
      CoTaskMemFree(mix_format);

      if (should_uninitialize)
      {
        CoUninitialize();
      }

      throw std::runtime_error(
          "Could not start system audio capture.");
    }

    std::vector<BYTE> captured_audio;

    const auto start_time =
        std::chrono::steady_clock::now();

    while (true)
    {
      const auto now =
          std::chrono::steady_clock::now();

      const auto elapsed =
          std::chrono::duration_cast<
              std::chrono::milliseconds>(
              now - start_time)
              .count();

      if (elapsed >= duration_ms)
      {
        break;
      }

      UINT32 packet_length = 0;

      hr = capture_client
               ->GetNextPacketSize(
                   &packet_length);

      if (FAILED(hr))
      {
        break;
      }

      while (packet_length != 0)
      {
        BYTE *data = nullptr;

        UINT32 frames = 0;

        DWORD flags = 0;

        hr = capture_client->GetBuffer(
            &data,
            &frames,
            &flags,
            nullptr,
            nullptr);

        if (FAILED(hr))
        {
          packet_length = 0;
          break;
        }

        const size_t byte_count =
            static_cast<size_t>(
                frames) *
            mix_format->nBlockAlign;

        const size_t old_size =
            captured_audio.size();

        captured_audio.resize(
            old_size + byte_count);

        if ((flags &
             AUDCLNT_BUFFERFLAGS_SILENT) !=
            0)
        {
          memset(
              captured_audio.data() +
                  old_size,
              0,
              byte_count);
        }
        else if (data != nullptr)
        {
          memcpy(
              captured_audio.data() +
                  old_size,
              data,
              byte_count);
        }

        capture_client->ReleaseBuffer(
            frames);

        hr = capture_client
                 ->GetNextPacketSize(
                     &packet_length);

        if (FAILED(hr))
        {
          packet_length = 0;
        }
      }

      std::this_thread::sleep_for(
          std::chrono::milliseconds(5));
    }

    audio_client->Stop();

    result.file_path =
        GetCapturePath();

    result.audio_bytes =
        captured_audio.size();

    const bool written =
        WriteWaveFile(
            result.file_path,
            mix_format,
            captured_audio);

    CoTaskMemFree(mix_format);

    if (should_uninitialize)
    {
      CoUninitialize();
    }

    if (!written)
    {
      throw std::runtime_error(
          "Could not write captured WAV file.");
    }

    return result;
  }

  std::string WideToUtf8(
      const std::wstring &text)
  {
    if (text.empty())
    {
      return std::string();
    }

    const int size_needed =
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

    std::string result(
        size_needed,
        0);

    WideCharToMultiByte(
        CP_UTF8,
        0,
        text.c_str(),
        static_cast<int>(
            text.size()),
        result.data(),
        size_needed,
        nullptr,
        nullptr);

    return result;
  }

} // namespace

FlutterWindow::FlutterWindow(
    const flutter::DartProject &project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate()
{
  if (!Win32Window::OnCreate())
  {
    return false;
  }

  RECT frame =
      GetClientArea();

  flutter_controller_ =
      std::make_unique<
          flutter::FlutterViewController>(
          frame.right - frame.left,
          frame.bottom - frame.top,
          project_);

  if (!flutter_controller_
           ->engine() ||
      !flutter_controller_
           ->view())
  {
    return false;
  }

  RegisterPlugins(
      flutter_controller_
          ->engine());

  auto channel =
      std::make_unique<
          flutter::MethodChannel<
              flutter::EncodableValue>>(
          flutter_controller_
              ->engine()
              ->messenger(),
          "lyrics_app/system_audio",
          &flutter::StandardMethodCodec::
              GetInstance());

  channel->SetMethodCallHandler(
      [](const flutter::MethodCall<
             flutter::EncodableValue> &call,
         std::unique_ptr<
             flutter::MethodResult<
                 flutter::EncodableValue>>
             result)
      {
        if (call.method_name() !=
            "captureSystemAudio")
        {
          result->NotImplemented();
          return;
        }

        int duration_ms = 6000;

        const auto *arguments =
            std::get_if<
                flutter::EncodableMap>(
                call.arguments());

        if (arguments != nullptr)
        {
          const auto iterator =
              arguments->find(
                  flutter::EncodableValue(
                      "durationMs"));

          if (iterator !=
              arguments->end())
          {
            if (const int32_t *value32 =
                    std::get_if<int32_t>(
                        &iterator->second))
            {
              duration_ms = *value32;
            }
            else if (
                const int64_t *value64 =
                    std::get_if<int64_t>(
                        &iterator->second))
            {
              duration_ms =
                  static_cast<int>(
                      *value64);
            }
          }
        }

        try
        {
          const CaptureResult capture =
              CaptureSystemAudio(
                  duration_ms);

          flutter::EncodableMap response;

          response[flutter::EncodableValue(
              "filePath")] =
              flutter::EncodableValue(
                  WideToUtf8(
                      capture.file_path));

          response[flutter::EncodableValue(
              "bytes")] =
              flutter::EncodableValue(
                  static_cast<int64_t>(
                      capture.audio_bytes));

          response[flutter::EncodableValue(
              "sampleRate")] =
              flutter::EncodableValue(
                  capture.sample_rate);

          response[flutter::EncodableValue(
              "channels")] =
              flutter::EncodableValue(
                  capture.channels);

          response[flutter::EncodableValue(
              "bitsPerSample")] =
              flutter::EncodableValue(
                  capture.bits_per_sample);

          result->Success(
              flutter::EncodableValue(
                  response));
        }
        catch (
            const std::exception &e)
        {
          result->Error(
              "WASAPI_CAPTURE_ERROR",
              e.what());
        }
      });

  system_audio_channel_ =
      std::move(channel);

  SetChildContent(
      flutter_controller_
          ->view()
          ->GetNativeWindow());

  flutter_controller_
      ->engine()
      ->SetNextFrameCallback(
          [this]()
          {
            this->Show();
          });

  flutter_controller_
      ->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy()
{
  if (flutter_controller_)
  {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT FlutterWindow::MessageHandler(
    HWND hwnd,
    UINT const message,
    WPARAM const wparam,
    LPARAM const lparam) noexcept
{
  if (flutter_controller_)
  {
    std::optional<LRESULT> result =
        flutter_controller_
            ->HandleTopLevelWindowProc(
                hwnd,
                message,
                wparam,
                lparam);

    if (result)
    {
      return *result;
    }
  }

  switch (message)
  {
  case WM_FONTCHANGE:
    flutter_controller_
        ->engine()
        ->ReloadSystemFonts();

    break;
  }

  return Win32Window::MessageHandler(
      hwnd,
      message,
      wparam,
      lparam);
}