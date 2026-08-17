"""Subtitle Traditional-Chinese conversion."""

import pytest


_SIMPLIFIED_VTT = """WEBVTT

00:00:00.000 --> 00:00:02.000
简体中文测试

00:00:02.000 --> 00:00:04.000
这是一个测试
"""


def _write(youtube_id: str, lang: str, text: str):
    from app.downloader import AUDIO_DIR

    path = AUDIO_DIR / f"{youtube_id}.{lang}.vtt"
    path.write_text(text, encoding="utf-8")
    return path


def test_zh_hans_subtitle_converted_to_traditional():
    from app.downloader import _select_subtitle

    _write("vid_hans", "zh-Hans", _SIMPLIFIED_VTT)
    selected = _select_subtitle("vid_hans")
    assert selected is not None
    content = open(selected, encoding="utf-8").read()
    assert "簡體中文測試" in content
    assert "简体" not in content


def test_bare_zh_subtitle_converted_to_traditional():
    from app.downloader import _select_subtitle

    _write("vid_zh", "zh", _SIMPLIFIED_VTT)
    selected = _select_subtitle("vid_zh")
    assert selected is not None
    content = open(selected, encoding="utf-8").read()
    assert "這是一個測試" in content


def test_existing_traditional_used_as_is():
    from app.downloader import _select_subtitle

    trad = "WEBVTT\n\n00:00:00.000 --> 00:00:02.000\n繁體中文\n"
    _write("vid_hant", "zh-Hant", trad)
    selected = _select_subtitle("vid_hant")
    assert selected is not None
    assert "繁體中文" in open(selected, encoding="utf-8").read()
