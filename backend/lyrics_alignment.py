"""Whisper word timestamps converted to the app's Enhanced LRC contract."""

from __future__ import annotations

from difflib import SequenceMatcher
import math
from pathlib import Path
import re
import unicodedata

from openai import OpenAI


MAX_AUDIO_BYTES = 25 * 1024 * 1024
# whisper-1 accepts at most 224 prompt tokens. Keep a short, plain-lyrics excerpt;
# the complete lyrics are still used to check and format the returned words.
MAX_PROMPT_CHARACTERS = 200


class AlignmentError(ValueError):
    """The transcription cannot safely be presented as aligned source lyrics."""


def _key(word: str) -> str:
    folded = unicodedata.normalize("NFKD", word.casefold())
    return "".join(character for character in folded
                   if character.isalnum() and not unicodedata.combining(character))


def _timestamp(seconds: float) -> str:
    centiseconds = round(seconds * 100)
    minutes, remainder = divmod(centiseconds, 6000)
    return f"{minutes:02d}:{remainder // 100:02d}.{remainder % 100:02d}"


def _source_lines(lyrics: str) -> list[list[str]]:
    return [re.findall(r"\S+", line) for line in lyrics.splitlines()
            if line.strip() and not re.fullmatch(r"\s*\[[^]]+\]\s*", line)]


def _enhanced_lrc(lyrics: str, words: list) -> str:
    lines = _source_lines(lyrics)
    source = [(line_index, token) for line_index, line in enumerate(lines) for token in line]
    if not source:
        raise AlignmentError("A letra não contém palavras.")

    heard = []
    for word in words or []:
        token = getattr(word, "word", "")
        start, end = getattr(word, "start", None), getattr(word, "end", None)
        if (not isinstance(token, str) or not isinstance(start, (int, float))
                or not isinstance(end, (int, float)) or not math.isfinite(start)
                or not math.isfinite(end) or start < 0 or end <= start):
            continue
        heard.append((token, float(start), float(end)))

    source_keys = [_key(token) for _, token in source]
    heard_keys = [_key(token) for token, _, _ in heard]
    matches = SequenceMatcher(a=source_keys, b=heard_keys, autojunk=False).get_matching_blocks()
    paired = [(source_index + offset, heard_index + offset)
              for source_index, heard_index, length in matches for offset in range(length)
              if source_keys[source_index + offset]]
    if len(paired) / len(source) < 0.8:
        raise AlignmentError("A transcrição diverge da letra original.")

    aligned: list[list[tuple[str, float, float]]] = [[] for _ in lines]
    previous_start = -1.0
    for source_index, heard_index in paired:
        line_index, original = source[source_index]
        _, start, end = heard[heard_index]
        if start < previous_start:
            raise AlignmentError("A transcrição devolveu tempos fora de ordem.")
        previous_start = start
        aligned[line_index].append((original, start, end))

    result = []
    for line in aligned:
        if not line:
            continue
        chunks = [f"<{_timestamp(start)}> {token} <{_timestamp(end)}>"
                  for token, start, end in line]
        result.append(f"[{_timestamp(line[0][1])}] " + " ".join(chunks))
    return "\n".join(result)


def generate_enhanced_lrc(audio_path: Path, lyrics: str) -> str:
    """Guide Whisper with source lyrics and retain only words matched to them.

    The prompt is context, not a true forced-alignment guarantee. Mismatched
    transcription words are never passed on to the karaoke UI as source lyrics.
    """
    if audio_path.stat().st_size > MAX_AUDIO_BYTES:
        raise AlignmentError("O áudio excede o limite de 25 MB da transcrição.")
    if not _source_lines(lyrics):
        raise AlignmentError("A letra não contém palavras.")
    prompt = "\n".join(" ".join(line) for line in _source_lines(lyrics))[:MAX_PROMPT_CHARACTERS]
    with audio_path.open("rb") as audio:
        response = OpenAI(timeout=120).audio.transcriptions.create(
            model="whisper-1",
            file=audio,
            response_format="verbose_json",
            timestamp_granularities=["word"],
            prompt=prompt,
        )
    return _enhanced_lrc(lyrics, response.words)
