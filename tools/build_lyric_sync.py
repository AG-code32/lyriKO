import argparse
import json
import re
import statistics
import unicodedata
from difflib import SequenceMatcher
from pathlib import Path


WORD_PATTERN = re.compile(
    r"[A-Za-z0-9À-ÿ]+(?:['’][A-Za-z0-9À-ÿ]+)*"
)


#
# =====================================================
# ACOUSTIC VALIDATION
# =====================================================
#
# ctc-forced-aligner produces a score for every aligned
# segment.
#
# Higher / closer to zero = better acoustic agreement.
#
# On the correctly aligned Nobody reference:
#
# median score  ≈ -0.54
# mean score    ≈ -0.83
# >= -2.0       ≈ 92%
#
# These limits deliberately leave substantial margin
# for difficult vocals while rejecting obviously
# unrelated audio/transcript combinations.
#

GOOD_SCORE_THRESHOLD = -2.0
VERY_BAD_SCORE_THRESHOLD = -4.0

MIN_MEDIAN_SCORE = -1.80
MIN_MEAN_SCORE = -2.20

MIN_GOOD_SCORE_RATIO = 0.60
MAX_VERY_BAD_SCORE_RATIO = 0.25

MIN_SCORED_SEGMENT_RATIO = 0.70


#
# =====================================================
# LINE MATCHING
# =====================================================
#

MIN_LINE_SCORE = 0.48
MIN_LINE_WORD_COVERAGE = 0.45

MIN_TOTAL_WORD_COVERAGE = 0.55
MIN_TOTAL_LINE_COVERAGE = 0.70

MAX_INFERRED_LINE_RATIO = 0.20

FUZZY_WORD_THRESHOLD = 0.72

LOCAL_SEARCH_AHEAD = 12

CANDIDATE_LENGTH_BELOW = 3
CANDIDATE_LENGTH_ABOVE = 4


def parse_args():
    parser = argparse.ArgumentParser(
        description=(
            "Convert CTC forced-alignment output "
            "into Lyriko synchronized lyrics JSON."
        )
    )

    parser.add_argument(
        "--lyrics",
        required=True,
    )

    parser.add_argument(
        "--aligned",
        required=True,
    )

    parser.add_argument(
        "--output",
        required=True,
    )

    parser.add_argument(
        "--song-id",
        required=True,
    )

    parser.add_argument(
        "--title",
        required=True,
    )

    parser.add_argument(
        "--artist",
        required=True,
    )

    parser.add_argument(
        "--audio",
        required=True,
    )

    return parser.parse_args()


def ms(seconds):
    return int(
        round(
            float(seconds) * 1000
        )
    )


def normalize_word(value):
    value = str(
        value
    ).strip().lower()

    value = value.replace(
        "’",
        "'",
    )

    value = unicodedata.normalize(
        "NFKD",
        value,
    )

    value = "".join(
        char
        for char in value
        if not unicodedata.combining(
            char
        )
    )

    value = re.sub(
        r"[^a-z0-9']",
        "",
        value,
    )

    return value


def extract_words(line):
    result = []

    for match in WORD_PATTERN.finditer(
        line
    ):
        display = (
            match.group(0)
        )

        normalized = normalize_word(
            display
        )

        if not normalized:
            continue

        result.append(
            {
                "display":
                    display,

                "normalized":
                    normalized,
            }
        )

    return result


def build_ctc_tokens(
    segments,
):
    result = []

    for segment_index, segment in enumerate(
        segments
    ):
        raw_text = str(
            segment.get(
                "text",
                "",
            )
        ).strip()

        normalized = normalize_word(
            raw_text
        )

        if not normalized:
            continue

        score = segment.get(
            "score"
        )

        if not isinstance(
            score,
            (int, float),
        ):
            score = None

        result.append(
            {
                "segmentIndex":
                    segment_index,

                "display":
                    raw_text,

                "normalized":
                    normalized,

                "startMs":
                    ms(
                        segment[
                            "start"
                        ]
                    ),

                "endMs":
                    ms(
                        segment[
                            "end"
                        ]
                    ),

                "score":
                    score,
            }
        )

    return result


def validate_acoustic_alignment(
    segments,
):
    scores = []

    for segment in segments:
        score = segment.get(
            "score"
        )

        if isinstance(
            score,
            (int, float),
        ):
            scores.append(
                float(
                    score
                )
            )

    scored_ratio = (
        len(scores) /
        max(
            1,
            len(segments),
        )
    )

    print()
    print(
        "ACOUSTIC VALIDATION"
    )

    print(
        f"Scored segments: "
        f"{len(scores)}/"
        f"{len(segments)} "
        f"({scored_ratio * 100:.1f}%)"
    )

    if (
        scored_ratio
        <
        MIN_SCORED_SEGMENT_RATIO
    ):
        raise RuntimeError(
            "\nAcoustic validation failed.\n\n"
            "The forced aligner did not provide "
            "enough acoustic confidence scores.\n\n"
            f"Scored segments: "
            f"{scored_ratio * 100:.1f}%"
        )

    if not scores:
        raise RuntimeError(
            "Acoustic validation failed: "
            "no CTC scores were available."
        )

    mean_score = (
        statistics.mean(
            scores
        )
    )

    median_score = (
        statistics.median(
            scores
        )
    )

    good_count = sum(
        1
        for score in scores
        if score >=
        GOOD_SCORE_THRESHOLD
    )

    very_bad_count = sum(
        1
        for score in scores
        if score <=
        VERY_BAD_SCORE_THRESHOLD
    )

    good_ratio = (
        good_count /
        len(scores)
    )

    very_bad_ratio = (
        very_bad_count /
        len(scores)
    )

    print(
        f"Mean CTC score: "
        f"{mean_score:.3f}"
    )

    print(
        f"Median CTC score: "
        f"{median_score:.3f}"
    )

    print(
        f"Good acoustic segments "
        f"(>= {GOOD_SCORE_THRESHOLD}): "
        f"{good_ratio * 100:.1f}%"
    )

    print(
        f"Very bad acoustic segments "
        f"(<= {VERY_BAD_SCORE_THRESHOLD}): "
        f"{very_bad_ratio * 100:.1f}%"
    )

    failures = []

    if (
        median_score
        <
        MIN_MEDIAN_SCORE
    ):
        failures.append(
            (
                "Median CTC score is too low "
                f"({median_score:.3f})"
            )
        )

    if (
        mean_score
        <
        MIN_MEAN_SCORE
    ):
        failures.append(
            (
                "Mean CTC score is too low "
                f"({mean_score:.3f})"
            )
        )

    if (
        good_ratio
        <
        MIN_GOOD_SCORE_RATIO
    ):
        failures.append(
            (
                "Too few segments match the "
                "audio acoustically "
                f"({good_ratio * 100:.1f}%)"
            )
        )

    if (
        very_bad_ratio
        >
        MAX_VERY_BAD_SCORE_RATIO
    ):
        failures.append(
            (
                "Too many segments have very "
                "poor acoustic confidence "
                f"({very_bad_ratio * 100:.1f}%)"
            )
        )

    if failures:
        detail = "\n".join(
            f"- {failure}"
            for failure in failures
        )

        raise RuntimeError(
            "\nAlignment validation failed.\n\n"
            "The pasted lyrics do not appear "
            "to match the selected audio reliably.\n\n"
            f"{detail}\n\n"
            "Check that the MP3 and lyrics belong "
            "to the same song."
        )

    return {
        "meanScore":
            round(
                mean_score,
                4,
            ),

        "medianScore":
            round(
                median_score,
                4,
            ),

        "goodScoreRatio":
            round(
                good_ratio,
                4,
            ),

        "veryBadScoreRatio":
            round(
                very_bad_ratio,
                4,
            ),

        "scoredSegmentRatio":
            round(
                scored_ratio,
                4,
            ),
    }


def similarity(
    a,
    b,
):
    if not a or not b:
        return 0.0

    if a == b:
        return 1.0

    return SequenceMatcher(
        None,
        a,
        b,
        autojunk=False,
    ).ratio()


def evaluate_candidate(
    lyric_words,
    ctc_tokens,
    start_index,
    length,
    expected_cursor,
):
    end_index = min(
        len(ctc_tokens),
        start_index +
        length,
    )

    candidate = ctc_tokens[
        start_index:end_index
    ]

    if not candidate:
        return None

    lyric_normalized = [
        word[
            "normalized"
        ]
        for word in lyric_words
    ]

    ctc_normalized = [
        token[
            "normalized"
        ]
        for token in candidate
    ]

    matcher = SequenceMatcher(
        None,
        lyric_normalized,
        ctc_normalized,
        autojunk=False,
    )

    matching_blocks = (
        matcher.get_matching_blocks()
    )

    exact_matches = sum(
        block.size
        for block
        in matching_blocks
    )

    exact_coverage = (
        exact_matches /
        max(
            1,
            len(
                lyric_words
            ),
        )
    )

    sequence_ratio = (
        matcher.ratio()
    )

    length_difference = abs(
        len(candidate) -
        len(lyric_words)
    )

    length_penalty = (
        length_difference /
        max(
            1,
            len(
                lyric_words
            ),
        )
    )

    cursor_distance = abs(
        start_index -
        expected_cursor
    )

    cursor_penalty = min(
        0.18,
        cursor_distance *
        0.018,
    )

    score = (
        sequence_ratio *
        0.52
        +
        exact_coverage *
        0.48
        -
        length_penalty *
        0.08
        -
        cursor_penalty
    )

    return {
        "score":
            score,

        "exactCoverage":
            exact_coverage,

        "sequenceRatio":
            sequence_ratio,

        "start":
            start_index,

        "end":
            end_index,

        "tokens":
            candidate,
    }


def find_best_line_candidate(
    lyric_words,
    ctc_tokens,
    cursor,
):
    if not lyric_words:
        return None

    if (
        cursor >=
        len(
            ctc_tokens
        )
    ):
        return None

    word_count = len(
        lyric_words
    )

    search_start = max(
        0,
        cursor - 1,
    )

    search_end = min(
        len(
            ctc_tokens
        ),
        cursor +
        LOCAL_SEARCH_AHEAD +
        1,
    )

    minimum_length = max(
        1,
        word_count -
        CANDIDATE_LENGTH_BELOW,
    )

    maximum_length = (
        word_count +
        CANDIDATE_LENGTH_ABOVE
    )

    best = None

    for start_index in range(
        search_start,
        search_end,
    ):
        for length in range(
            minimum_length,
            maximum_length +
            1,
        ):
            if (
                start_index +
                length
                >
                len(
                    ctc_tokens
                )
            ):
                break

            candidate = (
                evaluate_candidate(
                    lyric_words,
                    ctc_tokens,
                    start_index,
                    length,
                    cursor,
                )
            )

            if candidate is None:
                continue

            if (
                best is None
                or
                candidate[
                    "score"
                ]
                >
                best[
                    "score"
                ]
            ):
                best = candidate

    if best is None:
        return None

    if (
        best["score"]
        <
        MIN_LINE_SCORE
    ):
        return None

    if (
        best[
            "exactCoverage"
        ]
        <
        MIN_LINE_WORD_COVERAGE
    ):
        return None

    return best


def build_word_matches(
    lyric_words,
    candidate_tokens,
):
    lyric_normalized = [
        item[
            "normalized"
        ]
        for item in lyric_words
    ]

    ctc_normalized = [
        item[
            "normalized"
        ]
        for item
        in candidate_tokens
    ]

    matcher = SequenceMatcher(
        None,
        lyric_normalized,
        ctc_normalized,
        autojunk=False,
    )

    matches = []

    used_ctc = set()

    for block in matcher.get_matching_blocks():
        for offset in range(
            block.size
        ):
            lyric_index = (
                block.a +
                offset
            )

            ctc_index = (
                block.b +
                offset
            )

            used_ctc.add(
                ctc_index
            )

            matches.append(
                {
                    "lyricIndex":
                        lyric_index,

                    "ctcIndex":
                        ctc_index,

                    "text":
                        lyric_words[
                            lyric_index
                        ][
                            "display"
                        ],

                    "startMs":
                        candidate_tokens[
                            ctc_index
                        ][
                            "startMs"
                        ],

                    "endMs":
                        candidate_tokens[
                            ctc_index
                        ][
                            "endMs"
                        ],
                }
            )

    matched_lyric_indices = {
        item[
            "lyricIndex"
        ]
        for item in matches
    }

    for lyric_index, lyric_word in enumerate(
        lyric_words
    ):
        if (
            lyric_index
            in
            matched_lyric_indices
        ):
            continue

        best_ctc_index = None

        best_score = 0.0

        for ctc_index, ctc_word in enumerate(
            candidate_tokens
        ):
            if (
                ctc_index
                in
                used_ctc
            ):
                continue

            score = similarity(
                lyric_word[
                    "normalized"
                ],
                ctc_word[
                    "normalized"
                ],
            )

            if score > best_score:
                best_score = score

                best_ctc_index = (
                    ctc_index
                )

        if (
            best_ctc_index
            is not None
            and
            best_score
            >=
            FUZZY_WORD_THRESHOLD
        ):
            used_ctc.add(
                best_ctc_index
            )

            matches.append(
                {
                    "lyricIndex":
                        lyric_index,

                    "ctcIndex":
                        best_ctc_index,

                    "text":
                        lyric_word[
                            "display"
                        ],

                    "startMs":
                        candidate_tokens[
                            best_ctc_index
                        ][
                            "startMs"
                        ],

                    "endMs":
                        candidate_tokens[
                            best_ctc_index
                        ][
                            "endMs"
                        ],
                }
            )

    matches.sort(
        key=lambda item:
            item[
                "ctcIndex"
            ]
    )

    return matches


def align_lines(
    lyric_lines,
    ctc_tokens,
):
    aligned_lines = []

    cursor = 0

    total_words = 0

    matched_words = 0

    for text in lyric_lines:
        lyric_words = extract_words(
            text
        )

        total_words += len(
            lyric_words
        )

        if not lyric_words:
            aligned_lines.append(
                {
                    "text":
                        text,

                    "matches":
                        [],

                    "timing":
                        None,

                    "inferred":
                        True,
                }
            )

            continue

        candidate = (
            find_best_line_candidate(
                lyric_words,
                ctc_tokens,
                cursor,
            )
        )

        if candidate is None:
            aligned_lines.append(
                {
                    "text":
                        text,

                    "matches":
                        [],

                    "timing":
                        None,

                    "inferred":
                        True,
                }
            )

            continue

        matches = (
            build_word_matches(
                lyric_words,
                candidate[
                    "tokens"
                ],
            )
        )

        matched_words += len(
            matches
        )

        if not matches:
            aligned_lines.append(
                {
                    "text":
                        text,

                    "matches":
                        [],

                    "timing":
                        None,

                    "inferred":
                        True,
                }
            )

            cursor = max(
                cursor,
                candidate[
                    "end"
                ],
            )

            continue

        start_ms = min(
            match[
                "startMs"
            ]
            for match
            in matches
        )

        end_ms = max(
            match[
                "endMs"
            ]
            for match
            in matches
        )

        aligned_lines.append(
            {
                "text":
                    text,

                "matches":
                    matches,

                "timing": {
                    "startMs":
                        start_ms,

                    "endMs":
                        end_ms,
                },

                "inferred":
                    False,
            }
        )

        cursor = max(
            cursor,
            candidate[
                "end"
            ],
        )

    return (
        aligned_lines,
        total_words,
        matched_words,
    )


def previous_known_index(
    lines,
    index,
):
    for i in range(
        index - 1,
        -1,
        -1,
    ):
        if (
            lines[i][
                "timing"
            ]
            is not None
        ):
            return i

    return None


def next_known_index(
    lines,
    index,
):
    for i in range(
        index + 1,
        len(lines),
    ):
        if (
            lines[i][
                "timing"
            ]
            is not None
        ):
            return i

    return None


def infer_missing_timings(
    aligned_lines,
):
    index = 0

    while (
        index <
        len(
            aligned_lines
        )
    ):
        if (
            aligned_lines[
                index
            ][
                "timing"
            ]
            is not None
        ):
            index += 1

            continue

        run_start = index

        while (
            index <
            len(
                aligned_lines
            )
            and
            aligned_lines[
                index
            ][
                "timing"
            ]
            is None
        ):
            index += 1

        run_end = (
            index - 1
        )

        count = (
            run_end -
            run_start +
            1
        )

        previous_index = (
            previous_known_index(
                aligned_lines,
                run_start,
            )
        )

        next_index = (
            next_known_index(
                aligned_lines,
                run_end,
            )
        )

        if (
            previous_index
            is not None
            and
            next_index
            is not None
        ):
            previous_end = (
                aligned_lines[
                    previous_index
                ][
                    "timing"
                ][
                    "endMs"
                ]
            )

            next_start = (
                aligned_lines[
                    next_index
                ][
                    "timing"
                ][
                    "startMs"
                ]
            )

            available = max(
                1,
                next_start -
                previous_end,
            )

            slot = max(
                1,
                available //
                (
                    count +
                    1
                ),
            )

            for offset in range(
                count
            ):
                start_ms = (
                    previous_end +
                    slot *
                    (
                        offset +
                        1
                    )
                )

                end_ms = (
                    start_ms +
                    max(
                        500,
                        slot - 1,
                    )
                )

                if (
                    end_ms >=
                    next_start
                ):
                    end_ms = max(
                        start_ms,
                        next_start -
                        1,
                    )

                aligned_lines[
                    run_start +
                    offset
                ][
                    "timing"
                ] = {
                    "startMs":
                        start_ms,

                    "endMs":
                        end_ms,
                }

                aligned_lines[
                    run_start +
                    offset
                ][
                    "inferred"
                ] = True

        elif (
            previous_index
            is not None
        ):
            current = (
                aligned_lines[
                    previous_index
                ][
                    "timing"
                ][
                    "endMs"
                ]
            )

            for offset in range(
                count
            ):
                start_ms = (
                    current +
                    500
                )

                end_ms = (
                    start_ms +
                    1500
                )

                aligned_lines[
                    run_start +
                    offset
                ][
                    "timing"
                ] = {
                    "startMs":
                        start_ms,

                    "endMs":
                        end_ms,
                }

                aligned_lines[
                    run_start +
                    offset
                ][
                    "inferred"
                ] = True

                current = (
                    end_ms
                )

        elif (
            next_index
            is not None
        ):
            next_start = (
                aligned_lines[
                    next_index
                ][
                    "timing"
                ][
                    "startMs"
                ]
            )

            slot = 1800

            first_start = max(
                0,
                next_start -
                slot *
                count,
            )

            for offset in range(
                count
            ):
                start_ms = (
                    first_start +
                    slot *
                    offset
                )

                end_ms = min(
                    next_start -
                    1,
                    start_ms +
                    1500,
                )

                aligned_lines[
                    run_start +
                    offset
                ][
                    "timing"
                ] = {
                    "startMs":
                        start_ms,

                    "endMs":
                        max(
                            start_ms,
                            end_ms,
                        ),
                }

                aligned_lines[
                    run_start +
                    offset
                ][
                    "inferred"
                ] = True


def enforce_monotonic_start_times(
    aligned_lines,
):
    previous_start = -1

    for item in aligned_lines:
        timing = item[
            "timing"
        ]

        if timing is None:
            continue

        start_ms = int(
            timing[
                "startMs"
            ]
        )

        end_ms = int(
            timing[
                "endMs"
            ]
        )

        if (
            start_ms <=
            previous_start
        ):
            start_ms = (
                previous_start +
                1
            )

        if (
            end_ms <
            start_ms
        ):
            end_ms = (
                start_ms
            )

        timing[
            "startMs"
        ] = start_ms

        timing[
            "endMs"
        ] = end_ms

        previous_start = (
            start_ms
        )


def main():
    args = parse_args()

    lyrics_path = Path(
        args.lyrics
    )

    aligned_path = Path(
        args.aligned
    )

    output_path = Path(
        args.output
    )

    audio_path = Path(
        args.audio
    )

    if not lyrics_path.exists():
        raise FileNotFoundError(
            f"Lyrics not found:\n"
            f"{lyrics_path}"
        )

    if not aligned_path.exists():
        raise FileNotFoundError(
            f"Alignment not found:\n"
            f"{aligned_path}"
        )

    if not audio_path.exists():
        raise FileNotFoundError(
            f"Audio not found:\n"
            f"{audio_path}"
        )

    lyric_lines = [
        line.strip()
        for line
        in lyrics_path
        .read_text(
            encoding="utf-8"
        )
        .splitlines()
        if line.strip()
    ]

    if not lyric_lines:
        raise RuntimeError(
            "Lyrics file contains no usable lines."
        )

    with aligned_path.open(
        "r",
        encoding="utf-8",
    ) as file:
        aligned = json.load(
            file
        )

    segments = aligned.get(
        "segments",
        [],
    )

    if not segments:
        raise RuntimeError(
            "No word segments were found "
            "in the forced-alignment JSON."
        )

    #
    # =================================================
    # FIRST:
    # Does the supplied text actually fit the audio?
    # =================================================
    #
    acoustic_metrics = (
        validate_acoustic_alignment(
            segments
        )
    )

    ctc_tokens = (
        build_ctc_tokens(
            segments
        )
    )

    if not ctc_tokens:
        raise RuntimeError(
            "CTC produced no usable words."
        )

    (
        aligned_lines,
        total_lyric_words,
        matched_words,
    ) = align_lines(
        lyric_lines,
        ctc_tokens,
    )

    matched_lines = sum(
        1
        for item in aligned_lines
        if (
            item[
                "timing"
            ]
            is not None
            and
            not item[
                "inferred"
            ]
        )
    )

    total_lines = len(
        aligned_lines
    )

    word_coverage = (
        matched_words /
        max(
            1,
            total_lyric_words,
        )
    )

    line_coverage = (
        matched_lines /
        max(
            1,
            total_lines,
        )
    )

    inferred_before_fill = (
        total_lines -
        matched_lines
    )

    inferred_ratio = (
        inferred_before_fill /
        max(
            1,
            total_lines,
        )
    )

    print()
    print(
        "TEXT / LINE VALIDATION"
    )

    print(
        f"Lyric words: "
        f"{total_lyric_words}"
    )

    print(
        f"Matched words: "
        f"{matched_words}"
    )

    print(
        f"Word coverage: "
        f"{word_coverage * 100:.1f}%"
    )

    print(
        f"Matched lines: "
        f"{matched_lines}/"
        f"{total_lines}"
    )

    print(
        f"Line coverage: "
        f"{line_coverage * 100:.1f}%"
    )

    print(
        f"Missing/inferred lines: "
        f"{inferred_before_fill}"
    )

    if (
        word_coverage
        <
        MIN_TOTAL_WORD_COVERAGE
    ):
        raise RuntimeError(
            "\nAlignment validation failed.\n\n"
            "Too few lyric words received "
            "reliable timing.\n\n"
            f"Word coverage: "
            f"{word_coverage * 100:.1f}%"
        )

    if (
        line_coverage
        <
        MIN_TOTAL_LINE_COVERAGE
    ):
        raise RuntimeError(
            "\nAlignment validation failed.\n\n"
            "Too few lyric lines received "
            "reliable automatic timing.\n\n"
            f"Line coverage: "
            f"{line_coverage * 100:.1f}%"
        )

    if (
        inferred_ratio
        >
        MAX_INFERRED_LINE_RATIO
    ):
        raise RuntimeError(
            "\nAlignment validation failed.\n\n"
            "Too many lyric lines would require "
            "estimated timestamps.\n\n"
            f"Inferred lines: "
            f"{inferred_before_fill}/"
            f"{total_lines} "
            f"({inferred_ratio * 100:.1f}%)"
        )

    infer_missing_timings(
        aligned_lines
    )

    enforce_monotonic_start_times(
        aligned_lines
    )

    output_lines = []

    inferred_count = 0

    for item in aligned_lines:
        timing = item[
            "timing"
        ]

        if timing is None:
            raise RuntimeError(
                "Internal error: lyric line "
                "still has no timing."
            )

        if item[
            "inferred"
        ]:
            inferred_count += 1

        words_json = [
            {
                "text":
                    match[
                        "text"
                    ],

                "startMs":
                    match[
                        "startMs"
                    ],

                "endMs":
                    match[
                        "endMs"
                    ],
            }
            for match
            in item[
                "matches"
            ]
        ]

        original_start_ms = int(
            timing[
                "startMs"
            ]
        )

        original_end_ms = int(
            timing[
                "endMs"
            ]
        )

        output_lines.append(
            {
                "text":
                    item[
                        "text"
                    ],

                "originalStartMs":
                    original_start_ms,

                "originalEndMs":
                    original_end_ms,

                "startMs":
                    original_start_ms,

                "endMs":
                    original_end_ms,

                "words":
                    words_json,
            }
        )

    duration_ms = max(
        ms(
            segments[-1][
                "end"
            ]
        ),
        output_lines[-1][
            "endMs"
        ],
    )

    result = {
        "songId":
            args.song_id,

        "title":
            args.title,

        "artist":
            args.artist,

        "audioPath":
            str(
                audio_path
            ),

        "durationMs":
            duration_ms,

        "alignment": {
            "method":
                "sequential-local-acoustic-v3",

            "acoustic":
                acoustic_metrics,

            "totalLyricWords":
                total_lyric_words,

            "matchedWords":
                matched_words,

            "wordCoverage":
                round(
                    word_coverage,
                    4,
                ),

            "totalLines":
                total_lines,

            "matchedLines":
                matched_lines,

            "lineCoverage":
                round(
                    line_coverage,
                    4,
                ),

            "inferredLines":
                inferred_count,
        },

        "lines":
            output_lines,
    }

    output_path.parent.mkdir(
        parents=True,
        exist_ok=True,
    )

    output_path.write_text(
        json.dumps(
            result,
            indent=2,
            ensure_ascii=False,
        ),
        encoding="utf-8",
    )

    print()
    print(
        "SYNC CREATED"
    )

    print(
        f"Song: "
        f"{args.artist} - "
        f"{args.title}"
    )

    print(
        f"Lines: "
        f"{len(output_lines)}"
    )

    print(
        f"Word coverage: "
        f"{word_coverage * 100:.1f}%"
    )

    print(
        f"Line coverage: "
        f"{line_coverage * 100:.1f}%"
    )

    print(
        f"Median acoustic score: "
        f"{acoustic_metrics['medianScore']}"
    )

    print()

    print(
        "Matching method: "
        "sequential-local-acoustic-v3"
    )

    print()

    print(
        f"Saved to:\n"
        f"{output_path}"
    )


if __name__ == "__main__":
    main()