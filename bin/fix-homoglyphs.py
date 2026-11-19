#!/usr/bin/env python3
"""Replace Latin look-alike letters that Whisper drops inside Cyrillic words.

The speech model occasionally writes "привeт" with a Latin "e" (the glyphs are
identical in most fonts). A Latin letter inside a word that already contains
Cyrillic is almost certainly such a homoglyph, so it is mapped to the matching
Cyrillic letter. Words written entirely in Latin ("ok", "python", "covid-19")
are left untouched.

Usage: whisper-cli ... | fix-homoglyphs.py
"""

import re
import sys

TABLE = str.maketrans({
    "a": "а", "c": "с", "e": "е", "o": "о", "p": "р", "x": "х",
    "y": "у", "k": "к", "m": "м", "t": "т",
    "A": "А", "B": "В", "C": "С", "E": "Е", "H": "Н", "K": "К",
    "M": "М", "O": "О", "P": "Р", "R": "Р", "T": "Т", "X": "Х", "Y": "У",
})

WORD = re.compile(r"[A-Za-zА-Яа-яЁё]+")
CYRILLIC = re.compile(r"[А-Яа-яЁё]")
LATIN = re.compile(r"[A-Za-z]")


def fix_word(match):
    word = match.group(0)
    if CYRILLIC.search(word) and LATIN.search(word):
        return word.translate(TABLE)
    return word


def main():
    sys.stdout.write(WORD.sub(fix_word, sys.stdin.read()))


if __name__ == "__main__":
    main()
