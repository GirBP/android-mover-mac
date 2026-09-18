#!/usr/bin/env python3
"""3.7: парсить Sources/AndroidMover/**/*.swift (лише UI-таргет, AndroidMoverCore не чіпаємо),
збирає ключі з Text("…") і String(localized: "…") та ДОДАЄ відсутні у
Sources/AndroidMover/Resources/Localizable.xcstrings, зберігаючи наявні значення (лише
merge — ніколи не видаляє й не перезаписує вже присутній ключ). EN не додає: sourceLanguage
"uk" — ключ сам є текстом джерела, порожній запис `{}` цілком легальний String Catalog.

Свідомо НЕ намагається розібрати рядки з інтерпольованими значеннями (`\\(...)`) — String
Catalog очікує format-specifier-синтаксис (%lld/%@) для них, а не сирий Swift-код; такі
виклики просто пропускаються (не додаються в каталог), самé Text()/String(localized:) у коді
від цього не залежить і продовжує працювати як завжди.

Використання: python3 scripts/gen_strings.py [--check]
  --check   нічого не пише, лише друкує, скільки ключів додав би, і завершується з кодом 1,
            якщо каталог застарів (зручно для CI).
"""
import json
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
SOURCE_DIR = REPO_ROOT / "Sources" / "AndroidMover"
CATALOG_PATH = SOURCE_DIR / "Resources" / "Localizable.xcstrings"

# Захоплюємо вміст рядка з урахуванням екранованих лапок (\"), як звичайний Swift string literal.
STRING_LITERAL = r'"((?:[^"\\]|\\.)*)"'
TEXT_PATTERN = re.compile(r'\bText\(\s*' + STRING_LITERAL + r'\s*\)')
LOCALIZED_PATTERN = re.compile(r'String\(\s*localized:\s*' + STRING_LITERAL + r'\s*[,)]')


def unescape(raw: str) -> str:
    return raw.encode("utf-8").decode("unicode_escape", errors="ignore") if "\\" in raw else raw


def extract_keys(text: str) -> set[str]:
    keys: set[str] = set()
    for pattern in (TEXT_PATTERN, LOCALIZED_PATTERN):
        for match in pattern.finditer(text):
            raw = match.group(1)
            # Інтерпольовані рядки (\(...)) — не прості літерали, пропускаємо (див. docstring).
            if "\\(" in raw:
                continue
            key = unescape(raw)
            if key:
                keys.add(key)
    return keys


def collect_all_keys() -> set[str]:
    keys: set[str] = set()
    for path in sorted(SOURCE_DIR.rglob("*.swift")):
        keys |= extract_keys(path.read_text(encoding="utf-8"))
    return keys


def load_catalog() -> dict:
    if CATALOG_PATH.exists():
        return json.loads(CATALOG_PATH.read_text(encoding="utf-8"))
    return {"sourceLanguage": "uk", "strings": {}, "version": "1.0"}


def main() -> int:
    check_only = "--check" in sys.argv
    found = collect_all_keys()
    catalog = load_catalog()
    strings = catalog.setdefault("strings", {})

    added = sorted(key for key in found if key not in strings)
    for key in added:
        # Порожній об'єкт — легальний String Catalog запис "extracted, без стану/перекладів":
        # ключ сам є джерельним (uk) текстом, окрема uk-локалізація не обов'язкова.
        strings[key] = {}

    if check_only:
        print(f"Знайдено ключів: {len(found)}; відсутніх у каталозі: {len(added)}")
        return 1 if added else 0

    if added:
        catalog["strings"] = dict(sorted(strings.items()))
        CATALOG_PATH.write_text(
            json.dumps(catalog, ensure_ascii=False, indent=2, sort_keys=False) + "\n",
            encoding="utf-8",
        )
    print(f"Сканував {SOURCE_DIR}: знайдено {len(found)} ключів, додано {len(added)} нових.")
    for key in added:
        print(f"  + {key}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
