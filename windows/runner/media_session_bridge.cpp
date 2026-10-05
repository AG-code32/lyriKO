#include "media_session_bridge.h"

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <atomic>
#include <memory>
#include <string>
#include <vector>

#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Media.h>
#include <winrt/Windows.Media.Control.h>

using winrt::Windows::Foundation::AsyncStatus;
using winrt::Windows::Media::MediaPlaybackType;
using winrt::Windows::Media::Control::GlobalSystemMediaTransportControlsSession;
using winrt::Windows::Media::Control::GlobalSystemMediaTransportControlsSessionManager;
using winrt::Windows::Media::Control::GlobalSystemMediaTransportControlsSessionPlaybackStatus;

namespace {

GlobalSystemMediaTransportControlsSessionManager g_manager{nullptr};
bool g_initializing = false;

std::string ToUtf8(const winrt::hstring& value) {
  return winrt::to_string(value);
}

std::string PlaybackStatusToString(
    GlobalSystemMediaTransportControlsSessionPlaybackStatus status) {
  switch (status) {
    case GlobalSystemMediaTransportControlsSessionPlaybackStatus::Closed:
      return "closed";
    case GlobalSystemMediaTransportControlsSessionPlaybackStatus::Opened:
      return "opened";
    case GlobalSystemMediaTransportControlsSessionPlaybackStatus::Changing:
      return "changing";
    case GlobalSystemMediaTransportControlsSessionPlaybackStatus::Stopped:
      return "stopped";
    case GlobalSystemMediaTransportControlsSessionPlaybackStatus::Playing:
      return "playing";
    case GlobalSystemMediaTransportControlsSessionPlaybackStatus::Paused:
      return "paused";
  }
  return "unknown";
}

std::string PlaybackTypeToString(
    const winrt::Windows::Foundation::IReference<MediaPlaybackType>& value) {
  if (!value) return "unknown";

  switch (value.Value()) {
    case MediaPlaybackType::Music:
      return "music";
    case MediaPlaybackType::Video:
      return "video";
    case MediaPlaybackType::Image:
      return "image";
    default:
      return "unknown";
  }
}

int64_t TimeSpanToMilliseconds(winrt::Windows::Foundation::TimeSpan value) {
  return value.count() / 10000;
}

int64_t DateTimeToUnixMilliseconds(
    winrt::Windows::Foundation::DateTime value) {
  // Windows Runtime DateTime is expressed as 100 ns ticks since
  // 1601-01-01 UTC. Unix time starts at 1970-01-01 UTC.
  static constexpr int64_t kWindowsToUnixEpochMilliseconds =
      11644473600000LL;

  const int64_t windowsMilliseconds = value.time_since_epoch().count() / 10000;
  return windowsMilliseconds - kWindowsToUnixEpochMilliseconds;
}

double PlaybackRateToDouble(
    const winrt::Windows::Foundation::IReference<double>& value) {
  if (!value) return 1.0;
  return value.Value();
}

flutter::EncodableList GenresToList(
    const winrt::Windows::Foundation::Collections::IVectorView<winrt::hstring>&
        genres) {
  flutter::EncodableList result;
  for (const auto& genre : genres) {
    result.emplace_back(ToUtf8(genre));
  }
  return result;
}

flutter::EncodableMap EmptyState() {
  flutter::EncodableMap map;
  map[flutter::EncodableValue("available")] = flutter::EncodableValue(false);
  map[flutter::EncodableValue("playbackStatus")] =
      flutter::EncodableValue("unavailable");
  map[flutter::EncodableValue("sourceAppId")] = flutter::EncodableValue("");
  map[flutter::EncodableValue("positionMs")] =
      flutter::EncodableValue(static_cast<int64_t>(0));
  map[flutter::EncodableValue("lastUpdatedTimeMs")] =
      flutter::EncodableValue(static_cast<int64_t>(0));
  map[flutter::EncodableValue("playbackRate")] =
      flutter::EncodableValue(1.0);
  map[flutter::EncodableValue("startTimeMs")] =
      flutter::EncodableValue(static_cast<int64_t>(0));
  map[flutter::EncodableValue("endTimeMs")] =
      flutter::EncodableValue(static_cast<int64_t>(0));
  map[flutter::EncodableValue("title")] = flutter::EncodableValue("");
  map[flutter::EncodableValue("artist")] = flutter::EncodableValue("");
  map[flutter::EncodableValue("albumArtist")] = flutter::EncodableValue("");
  map[flutter::EncodableValue("albumTitle")] = flutter::EncodableValue("");
  map[flutter::EncodableValue("playbackType")] =
      flutter::EncodableValue("unknown");
  map[flutter::EncodableValue("trackNumber")] =
      flutter::EncodableValue(static_cast<int64_t>(0));
  map[flutter::EncodableValue("genres")] =
      flutter::EncodableValue(flutter::EncodableList{});
  return map;
}

flutter::EncodableMap ReadSessionBasic(
    const GlobalSystemMediaTransportControlsSession& session) {
  auto map = EmptyState();
  if (!session) return map;

  const auto playback = session.GetPlaybackInfo();
  const auto timeline = session.GetTimelineProperties();

  map[flutter::EncodableValue("available")] = flutter::EncodableValue(true);
  map[flutter::EncodableValue("playbackStatus")] = flutter::EncodableValue(
      PlaybackStatusToString(playback.PlaybackStatus()));
  map[flutter::EncodableValue("sourceAppId")] =
      flutter::EncodableValue(ToUtf8(session.SourceAppUserModelId()));
  map[flutter::EncodableValue("positionMs")] = flutter::EncodableValue(
      TimeSpanToMilliseconds(timeline.Position()));
  map[flutter::EncodableValue("lastUpdatedTimeMs")] = flutter::EncodableValue(
      DateTimeToUnixMilliseconds(timeline.LastUpdatedTime()));
  map[flutter::EncodableValue("playbackRate")] = flutter::EncodableValue(
      PlaybackRateToDouble(playback.PlaybackRate()));
  map[flutter::EncodableValue("startTimeMs")] = flutter::EncodableValue(
      TimeSpanToMilliseconds(timeline.StartTime()));
  map[flutter::EncodableValue("endTimeMs")] =
      flutter::EncodableValue(TimeSpanToMilliseconds(timeline.EndTime()));
  map[flutter::EncodableValue("playbackType")] = flutter::EncodableValue(
      PlaybackTypeToString(playback.PlaybackType()));

  return map;
}

void AddMetadata(
    flutter::EncodableMap& map,
    const winrt::Windows::Media::Control::
        GlobalSystemMediaTransportControlsSessionMediaProperties& properties) {
  map[flutter::EncodableValue("title")] =
      flutter::EncodableValue(ToUtf8(properties.Title()));
  map[flutter::EncodableValue("artist")] =
      flutter::EncodableValue(ToUtf8(properties.Artist()));
  map[flutter::EncodableValue("albumArtist")] =
      flutter::EncodableValue(ToUtf8(properties.AlbumArtist()));
  map[flutter::EncodableValue("albumTitle")] =
      flutter::EncodableValue(ToUtf8(properties.AlbumTitle()));
  map[flutter::EncodableValue("trackNumber")] =
      flutter::EncodableValue(static_cast<int64_t>(properties.TrackNumber()));
  map[flutter::EncodableValue("genres")] =
      flutter::EncodableValue(GenresToList(properties.Genres()));
}

void FinishSessionsRequest(
    const std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>>& result,
    const std::shared_ptr<std::vector<flutter::EncodableMap>>& maps,
    const std::shared_ptr<std::atomic<size_t>>& remaining) {
  if (remaining->fetch_sub(1) != 1) return;

  flutter::EncodableList list;
  for (const auto& map : *maps) {
    list.emplace_back(map);
  }
  result->Success(flutter::EncodableValue(std::move(list)));
}

}  // namespace

void RegisterMediaSessionBridge(flutter::BinaryMessenger* messenger) {
  auto channel = std::make_unique<
      flutter::MethodChannel<flutter::EncodableValue>>(
      messenger,
      "lyriko/media_session",
      &flutter::StandardMethodCodec::GetInstance());

  channel->SetMethodCallHandler([](const auto& call, auto result) {
    const std::string method = call.method_name();

    if (method == "initialize") {
      if (g_manager) {
        result->Success(flutter::EncodableValue(true));
        return;
      }

      if (g_initializing) {
        result->Success(flutter::EncodableValue(false));
        return;
      }

      g_initializing = true;
      auto operation =
          GlobalSystemMediaTransportControlsSessionManager::RequestAsync();
      auto shared_result =
          std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>>(
              std::move(result));

      operation.Completed([shared_result](const auto& operation,
                                          AsyncStatus status) {
        g_initializing = false;

        if (status != AsyncStatus::Completed) {
          shared_result->Error(
              "MEDIA_SESSION_INIT_FAILED",
              "Windows media session manager could not be initialized.");
          return;
        }

        try {
          g_manager = operation.GetResults();
          shared_result->Success(flutter::EncodableValue(true));
        } catch (const winrt::hresult_error& error) {
          shared_result->Error(
              "MEDIA_SESSION_INIT_FAILED",
              ToUtf8(error.message()));
        }
      });
      return;
    }

    if (method == "getState") {
      try {
        if (!g_manager) {
          result->Success(flutter::EncodableValue(EmptyState()));
          return;
        }

        const auto session = g_manager.GetCurrentSession();
        if (!session) {
          result->Success(flutter::EncodableValue(EmptyState()));
          return;
        }

        auto map = ReadSessionBasic(session);
        auto operation = session.TryGetMediaPropertiesAsync();
        auto shared_result =
            std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>>(
                std::move(result));

        operation.Completed(
            [shared_result, map = std::move(map)](
                const auto& operation, AsyncStatus status) mutable {
              if (status == AsyncStatus::Completed) {
                try {
                  AddMetadata(map, operation.GetResults());
                } catch (const winrt::hresult_error&) {
                }
              }
              shared_result->Success(
                  flutter::EncodableValue(std::move(map)));
            });
      } catch (const winrt::hresult_error& error) {
        result->Error("MEDIA_SESSION_READ_FAILED", ToUtf8(error.message()));
      }
      return;
    }

    if (method == "getSessions") {
      try {
        if (!g_manager) {
          result->Success(
              flutter::EncodableValue(flutter::EncodableList{}));
          return;
        }

        const auto sessions = g_manager.GetSessions();
        const size_t count = sessions.Size();

        if (count == 0) {
          result->Success(
              flutter::EncodableValue(flutter::EncodableList{}));
          return;
        }

        auto shared_result =
            std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>>(
                std::move(result));
        auto maps =
            std::make_shared<std::vector<flutter::EncodableMap>>(count);
        auto remaining = std::make_shared<std::atomic<size_t>>(count);

        for (size_t i = 0; i < count; i++) {
          const auto session = sessions.GetAt(static_cast<uint32_t>(i));
          (*maps)[i] = ReadSessionBasic(session);

          try {
            auto operation = session.TryGetMediaPropertiesAsync();
            operation.Completed(
                [shared_result, maps, remaining, i](
                    const auto& operation, AsyncStatus status) {
                  if (status == AsyncStatus::Completed) {
                    try {
                      AddMetadata((*maps)[i], operation.GetResults());
                    } catch (const winrt::hresult_error&) {
                    }
                  }
                  FinishSessionsRequest(shared_result, maps, remaining);
                });
          } catch (const winrt::hresult_error&) {
            FinishSessionsRequest(shared_result, maps, remaining);
          }
        }
      } catch (const winrt::hresult_error& error) {
        result->Error("MEDIA_SESSIONS_READ_FAILED", ToUtf8(error.message()));
      }
      return;
    }

    result->NotImplemented();
  });

  static std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      persistent_channel;
  persistent_channel = std::move(channel);
}
