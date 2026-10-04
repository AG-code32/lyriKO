import json
import os
import subprocess
import tempfile
from pathlib import Path


USER = os.environ["USERPROFILE"]

WHISPER_ROOT = Path(USER) / "Downloads" / "whisper.cpp"

WHISPER_EXE = (
    WHISPER_ROOT
    / "build"
    / "bin"
    / "Release"
    / "whisper-cli.exe"
)

MODEL = (
    WHISPER_ROOT
    / "models"
    / "ggml-base.en.bin"
)

ALBUM_FOLDER = Path(
    r"F:\Nueva carpeta\Avenged Sevenfold - Life Is But A Dream (2023) Mp3 320kbps (PMEDIA)"
)

OUTPUT_FOLDER = (
    Path(__file__).resolve().parent
    / "generated_sync"
)


def find_nobody():
    matches = list(
        ALBUM_FOLDER.glob("*Nobody*.mp3")
    )

    if not matches:
        raise FileNotFoundError(
            f'No MP3 containing "Nobody" found in:\n'
            f"{ALBUM_FOLDER}"
        )

    return matches[0]


def main():
    if not WHISPER_EXE.exists():
        raise FileNotFoundError(
            f"whisper-cli.exe not found:\n{WHISPER_EXE}"
        )

    if not MODEL.exists():
        raise FileNotFoundError(
            f"Whisper model not found:\n{MODEL}"
        )

    audio_file = find_nobody()

    OUTPUT_FOLDER.mkdir(
        parents=True,
        exist_ok=True,
    )

    print(f"Song found:\n{audio_file}\n")

    with tempfile.TemporaryDirectory() as temp_dir:
        temp_dir = Path(temp_dir)

        whisper_wav = (
            temp_dir
            / "nobody_whisper.wav"
        )

        output_base = (
            temp_dir
            / "nobody_whisper"
        )

        print(
            "Converting MP3 for Whisper..."
        )

        subprocess.run(
            [
                "ffmpeg",
                "-y",
                "-loglevel",
                "error",
                "-i",
                str(audio_file),
                "-ar",
                "16000",
                "-ac",
                "1",
                "-c:a",
                "pcm_s16le",
                str(whisper_wav),
            ],
            check=True,
        )

        print(
            "Running Whisper on complete song..."
        )

        subprocess.run(
            [
                str(WHISPER_EXE),
                "-m",
                str(MODEL),
                "-f",
                str(whisper_wav),
                "-l",
                "en",
                "-oj",
                "-of",
                str(output_base),
                "-np",
            ],
            cwd=str(WHISPER_ROOT),
            check=True,
        )

        whisper_json = Path(
            f"{output_base}.json"
        )

        if not whisper_json.exists():
            raise FileNotFoundError(
                "Whisper did not create JSON output."
            )

        with open(
            whisper_json,
            "r",
            encoding="utf-8",
        ) as file:
            data = json.load(file)

        output_path = (
            OUTPUT_FOLDER
            / "nobody_whisper_raw.json"
        )

        with open(
            output_path,
            "w",
            encoding="utf-8",
        ) as file:
            json.dump(
                data,
                file,
                indent=2,
                ensure_ascii=False,
            )

        print(
            "\nDone."
        )

        print(
            f"Saved to:\n{output_path}"
        )

        print(
            "\nTemporary WAV automatically deleted."
        )


if __name__ == "__main__":
    main()