import json
import re
from pathlib import Path


PROJECT_ROOT = Path(
    r"C:\Users\Gerson\Desktop\fluter_projects\Lyriko\lyrics_app"
)

LYRICS_PATH = (
    PROJECT_ROOT
    / "assets"
    / "lyrics"
    / "Avenged Sevenfold - Nobody.txt"
)

ALIGNED_PATH = Path(
    r"F:\Nueva carpeta\Avenged Sevenfold - Life Is But A Dream (2023) Mp3 320kbps (PMEDIA)\03. Nobody.json"
)

OUTPUT_PATH = (
    PROJECT_ROOT
    / "assets"
    / "lyrics"
    / "Avenged Sevenfold - Nobody.json"
)


WORD_PATTERN = re.compile(
    r"[A-Za-z0-9]+(?:['’][A-Za-z0-9]+)*"
)


def ms(seconds):
    return int(
        round(
            float(seconds) * 1000
        )
    )


def extract_display_words(line):
    matches = list(
        WORD_PATTERN.finditer(line)
    )

    result = []

    for index, match in enumerate(matches):
        start = match.start()

        if index + 1 < len(matches):
            end = matches[index + 1].start()
        else:
            end = len(line)

        display = line[start:end].strip()

        if not display:
            display = match.group(0)

        result.append(display)

    return result


def main():
    if not LYRICS_PATH.exists():
        raise FileNotFoundError(
            f"Lyrics not found:\n{LYRICS_PATH}"
        )

    if not ALIGNED_PATH.exists():
        raise FileNotFoundError(
            f"Alignment not found:\n{ALIGNED_PATH}"
        )

    lyric_lines = [
        line.strip()
        for line in LYRICS_PATH.read_text(
            encoding="utf-8"
        ).splitlines()
        if line.strip()
    ]

    with ALIGNED_PATH.open(
        "r",
        encoding="utf-8",
    ) as file:
        aligned = json.load(file)

    segments = aligned.get(
        "segments",
        [],
    )

    if not segments:
        raise RuntimeError(
            "No word segments were found "
            "in the forced-alignment JSON."
        )

    cursor = 0
    output_lines = []

    for lyric_line in lyric_lines:
        display_words = extract_display_words(
            lyric_line
        )

        word_count = len(
            display_words
        )

        if word_count == 0:
            continue

        if cursor + word_count > len(segments):
            raise RuntimeError(
                "\nAlignment ended too early.\n\n"
                f"Line:\n{lyric_line}\n\n"
                f"Needs {word_count} words, but only "
                f"{len(segments) - cursor} remain."
            )

        aligned_words = segments[
            cursor:cursor + word_count
        ]

        cursor += word_count

        words_json = []

        for display_word, segment in zip(
            display_words,
            aligned_words,
        ):
            start_ms = ms(
                segment["start"]
            )

            end_ms = ms(
                segment["end"]
            )

            words_json.append(
                {
                    "text": display_word,
                    "startMs": start_ms,
                    "endMs": end_ms,
                }
            )

        original_start_ms = (
            words_json[0]["startMs"]
        )

        original_end_ms = (
            words_json[-1]["endMs"]
        )

        output_lines.append(
            {
                "text": lyric_line,

                # CTC reference.
                # NEVER modified by manual calibration.
                "originalStartMs":
                    original_start_ms,

                "originalEndMs":
                    original_end_ms,

                # Working values.
                # Manual calibration modifies these.
                "startMs":
                    original_start_ms,

                "endMs":
                    original_end_ms,

                "words":
                    words_json,
            }
        )

    unused = (
        len(segments) - cursor
    )

    duration_ms = (
        output_lines[-1]["endMs"]
        if output_lines
        else 0
    )

    result = {
        "songId":
            "avenged-sevenfold-nobody",

        "title":
            "Nobody",

        "artist":
            "Avenged Sevenfold",

        "durationMs":
            duration_ms,

        "lines":
            output_lines,
    }

    OUTPUT_PATH.write_text(
        json.dumps(
            result,
            indent=2,
            ensure_ascii=False,
        ),
        encoding="utf-8",
    )

    print()
    print("SYNC CREATED")
    print(
        f"Lines: {len(output_lines)}"
    )
    print(
        f"Segments consumed: "
        f"{cursor}/{len(segments)}"
    )
    print(
        f"Unused segments: {unused}"
    )
    print()
    print(
        "CTC reference timestamps preserved "
        "as originalStartMs/originalEndMs"
    )
    print()
    print(
        f"Saved to:\n{OUTPUT_PATH}"
    )


if __name__ == "__main__":
    main()