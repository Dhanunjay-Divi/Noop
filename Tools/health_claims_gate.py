#!/usr/bin/env python3
"""Fail CI when user-facing copy makes a small set of unsafe health claims.

The gate intentionally does not attempt to lint every wellness sentence.  It
protects five release boundaries that must remain unambiguous until the product,
validation, and regulatory work exists:

* NOOP does not diagnose or detect AFib;
* NOOP does not measure or estimate blood pressure;
* fall detection is not an active safety feature;
* NOOP is not FDA-cleared, medical-grade, or clinical-grade; and
* mobile operating systems do not guarantee background synchronization.

Swift and Kotlin are scanned only inside string literals so implementation
identifiers, protocol enums, and developer comments cannot trip the copy gate.
String catalogs, Android value resources, marketing assets, and server static or
template assets are scanned as text.  The implementation uses only the Python
standard library so it can run before project dependencies are installed.
"""

from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Iterator, Sequence


ROOT = Path(__file__).resolve().parents[1]

CODE_SUFFIXES = frozenset({".swift", ".kt", ".kts"})
STRING_RESOURCE_SUFFIXES = frozenset(
    {".strings", ".stringsdict", ".xcstrings"}
)
WEB_SUFFIXES = frozenset(
    {
        ".css",
        ".html",
        ".htm",
        ".js",
        ".jsx",
        ".json",
        ".md",
        ".mjs",
        ".scss",
        ".text",
        ".ts",
        ".tsx",
        ".txt",
        ".vue",
    }
)

# Tests and generated/vendor trees may legitimately contain positive examples.
# They are not release copy, so including them would make the gate self-trigger.
EXCLUDED_DIRECTORY_NAMES = frozenset(
    {
        ".build",
        ".git",
        ".gradle",
        ".pytest_cache",
        ".ruff_cache",
        "build",
        "deriveddata",
        "dist",
        "node_modules",
        "pods",
        "test",
        "tests",
        "tools",
        "vendor",
    }
)


@dataclass(frozen=True)
class ClaimRule:
    identifier: str
    explanation: str
    patterns: tuple[re.Pattern[str], ...]


@dataclass(frozen=True, order=True)
class Finding:
    path: Path
    line: int
    column: int
    rule: str
    explanation: str
    excerpt: str

    def render(self, root: Path) -> str:
        try:
            display_path = self.path.relative_to(root)
        except ValueError:
            display_path = self.path
        return (
            f"{display_path}:{self.line}:{self.column}: "
            f"[{self.rule}] {self.explanation}: {self.excerpt}"
        )


def _pattern(expression: str) -> re.Pattern[str]:
    return re.compile(expression, re.IGNORECASE)


# Patterns begin at the medical predicate or feature name.  That lets the
# negation check distinguish "does not detect AFib" from a later affirmative
# clause such as "does not import ECGs, but detects AFib".
RULES = (
    ClaimRule(
        "afib-detection",
        "NOOP must not claim to diagnose, detect, identify, or screen for AFib",
        (
            _pattern(
                r"\b(?:diagnos(?:e|es|ed|ing)|detect(?:s|ed|ing)?|"
                r"identif(?:y|ies|ied|ying)|screen(?:s|ed|ing)?\s+(?:people\s+)?for)\b"
                r"(?:(?!\b(?:but|however|yet|although|whereas)\b)[^.!?;\n]){0,60}"
                r"\b(?:a[\s-]?fib|atrial\s+fibrillation)\b"
            ),
            _pattern(
                r"\b(?:a[\s-]?fib|atrial\s+fibrillation)\b"
                r"(?:(?!\b(?:but|however|yet|although|whereas)\b)[^.!?;\n]){0,24}"
                r"\b(?:detection|diagnosis|screening)\b"
            ),
        ),
    ),
    ClaimRule(
        "blood-pressure",
        "NOOP must not claim to measure or estimate blood pressure",
        (
            _pattern(
                r"\b(?:measur(?:e|es|ed|ing)|estimat(?:e|es|ed|ing))\b"
                r"(?:(?!\b(?:but|however|yet|although|whereas)\b)[^.!?;\n]){0,60}"
                r"\b(?:blood\s+pressure|BP)\b"
            ),
            _pattern(
                r"\b(?:blood\s+pressure|BP)\b"
                r"(?:(?!\b(?:but|however|yet|although|whereas)\b)[^.!?;\n]){0,28}"
                r"\b(?:measurement|estimation)\b"
            ),
        ),
    ),
    ClaimRule(
        "fall-detection",
        "fall detection must not be presented as an active safety feature",
        (
            _pattern(
                r"\b(?:automatic(?:ally)?|active|real[-\s]?time)?\s*"
                r"fall\s+detection\b"
            ),
            _pattern(
                r"\bdetect(?:s|ed|ing)?\b"
                r"(?:(?!\b(?:but|however|yet|although|whereas)\b)[^.!?;\n]){0,32}"
                r"\bfalls?\b"
            ),
        ),
    ),
    ClaimRule(
        "regulated-grade",
        "NOOP must not be described as FDA-cleared or medical/clinical-grade",
        (
            _pattern(
                r"\bFDA\b"
                r"(?:(?!\b(?:but|however|yet|although|whereas)\b)[^.!?;\n]){0,24}"
                r"\b"
                r"(?:approved|cleared|authorized|certified|registered)\b"
            ),
            _pattern(r"\b(?:medical|clinical)[-\s]+grade\b"),
        ),
    ),
    ClaimRule(
        "background-sync-guarantee",
        "background synchronization must not be described as guaranteed",
        (
            _pattern(
                r"\bguarante(?:e|es|ed|eing)\b"
                r"(?:(?!\b(?:but|however|yet|although|whereas)\b)[^.!?;\n]){0,48}"
                r"\bbackground\s+(?:sync(?:hronization)?|upload|transfer)s?\b"
            ),
            _pattern(
                r"\bbackground\s+(?:sync(?:hronization)?|upload|transfer)s?\b"
                r"(?:(?!\b(?:but|however|yet|although|whereas)\b)[^.!?;\n]){0,48}"
                r"\bguaranteed\b"
            ),
            _pattern(
                r"\balways\b"
                r"(?:(?!\b(?:but|however|yet|although|whereas)\b)[^.!?;\n]){0,24}"
                r"\b(?:syncs?|uploads?|transfers?)\b"
                r"(?:(?!\b(?:but|however|yet|although|whereas)\b)[^.!?;\n]){0,24}"
                r"\bin\s+(?:the\s+)?background\b"
            ),
        ),
    ),
)


_NEGATION = re.compile(
    r"\b(?:"
    r"not|never|no|cannot|can['’]t|doesn['’]t|does\s+not|do\s+not|"
    r"isn['’]t|is\s+not|aren['’]t|are\s+not|won['’]t|will\s+not|"
    r"without|lacks?|unsupported|unavailable|disabled"
    r")\b(?!\s+only\b)",
    re.IGNORECASE,
)
_ADVERSATIVE = re.compile(r"\b(?:but|however|yet|although|whereas)\b", re.IGNORECASE)
_LIMITING_SUFFIX = re.compile(
    r"^[\s\-—–,:()<>/]*"
    r"(?:(?:is|are|remains?|stays?|will\s+be|feature\s+is)\s+)?"
    r"(?:not|never)\s+(?:an?\s+)?"
    r"(?:active|available|enabled|offered|provided|supported|guaranteed|feature)\b"
    r"|^[\s\-—–,:()<>/]*(?:is\s+)?(?:unsupported|unavailable|disabled)\b",
    re.IGNORECASE,
)
_ESCAPED_WHITESPACE = re.compile(r"\\[nrt]")


def _last_clause_boundary(text: str, before: int) -> int:
    start = max(0, before - 180)
    window = text[start:before]
    punctuation = max(window.rfind(mark) for mark in ("\n", ".", "!", "?", ";"))
    boundary = start + punctuation + 1
    for match in _ADVERSATIVE.finditer(window):
        boundary = max(boundary, start + match.end())
    return boundary


def _next_clause_boundary(text: str, after: int) -> int:
    candidates = [
        index
        for mark in ("\n", ".", "!", "?", ";")
        if (index := text.find(mark, after)) >= 0
    ]
    return min(candidates) if candidates else min(len(text), after + 180)


def _is_negated(text: str, start: int, end: int) -> bool:
    """Return true only when a nearby limitation scopes over this claim.

    The bounded clause and adversative reset avoid allowing an unsafe claim just
    because some unrelated disclaimer appears earlier in the same paragraph.
    """

    clause_start = _last_clause_boundary(text, start)
    prefix = text[clause_start:start]
    # A negator may be separated by auxiliaries ("not intended to be used to")
    # but should remain close enough to scope over the predicate.
    recent_words = list(re.finditer(r"[\w'’]+", prefix))
    recent_start = recent_words[-8].start() if len(recent_words) >= 8 else 0
    if _NEGATION.search(prefix[recent_start:]):
        return True

    matched = text[start:end]
    if _NEGATION.search(matched):
        return True

    clause_end = _next_clause_boundary(text, end)
    suffix = text[end:clause_end]
    return _LIMITING_SUFFIX.search(suffix) is not None


def _is_research_only_fall_copy(text: str, start: int, end: int) -> bool:
    """Allow an explicitly inactive fall-research disclaimer, not a beta claim."""

    if not re.search(r"\b(?:research[-\s]+only|prototype)\b", text[max(0, start - 60) : end + 80], re.IGNORECASE):
        return False
    return re.search(
        r"\b(?:disabled|not\s+active|not\s+enabled|does\s+not\s+detect)\b",
        text[max(0, start - 60) : end + 100],
        re.IGNORECASE,
    ) is not None


def _scan_region(
    text: str,
    *,
    path: Path,
    region_start: int = 0,
    region_end: int | None = None,
) -> list[Finding]:
    end = len(text) if region_end is None else region_end
    source = text[region_start:end]
    # Treat escaped newlines in source literals as spaces without changing byte
    # offsets, so a claim cannot evade the gate by inserting "\\n".
    visible = _ESCAPED_WHITESPACE.sub(
        lambda match: " " * len(match.group(0)), source
    )
    findings: list[Finding] = []
    seen: set[tuple[str, int]] = set()

    for rule in RULES:
        for pattern in rule.patterns:
            for match in pattern.finditer(visible):
                absolute_start = region_start + match.start()
                absolute_end = region_start + match.end()
                key = (rule.identifier, absolute_start)
                if key in seen or _is_negated(text, absolute_start, absolute_end):
                    continue
                if rule.identifier == "fall-detection" and _is_research_only_fall_copy(
                    text, absolute_start, absolute_end
                ):
                    continue
                seen.add(key)
                line = text.count("\n", 0, absolute_start) + 1
                previous_newline = text.rfind("\n", 0, absolute_start)
                column = absolute_start - previous_newline
                excerpt_start = max(
                    text.rfind("\n", 0, absolute_start) + 1,
                    absolute_start - 70,
                )
                next_newline = text.find("\n", absolute_end)
                if next_newline < 0:
                    next_newline = len(text)
                excerpt_end = min(next_newline, absolute_end + 90)
                excerpt = re.sub(
                    r"\s+", " ", text[excerpt_start:excerpt_end].strip()
                )
                if len(excerpt) > 180:
                    excerpt = excerpt[:177].rstrip() + "..."
                findings.append(
                    Finding(
                        path=path,
                        line=line,
                        column=column,
                        rule=rule.identifier,
                        explanation=rule.explanation,
                        excerpt=excerpt,
                    )
                )
    return findings


def _code_string_spans(text: str) -> Iterator[tuple[int, int]]:
    """Yield Swift/Kotlin string-content spans with a small lexical scanner."""

    index = 0
    length = len(text)
    while index < length:
        if text.startswith("//", index):
            newline = text.find("\n", index + 2)
            index = length if newline < 0 else newline + 1
            continue
        if text.startswith("/*", index):
            # Swift permits nested block comments, so balance them here.
            depth = 1
            cursor = index + 2
            while cursor < length and depth:
                if text.startswith("/*", cursor):
                    depth += 1
                    cursor += 2
                elif text.startswith("*/", cursor):
                    depth -= 1
                    cursor += 2
                else:
                    cursor += 1
            index = cursor
            continue
        if text[index] == "'":
            # Kotlin character literal.
            index += 1
            while index < length:
                if text[index] == "\\":
                    index += 2
                elif text[index] == "'":
                    index += 1
                    break
                else:
                    index += 1
            continue

        raw_hashes = 0
        quote_index = index
        while quote_index < length and text[quote_index] == "#":
            raw_hashes += 1
            quote_index += 1
        if quote_index >= length or text[quote_index] != '"':
            index += 1
            continue

        triple = text.startswith('"""', quote_index)
        opening_size = 3 if triple else 1
        content_start = quote_index + opening_size
        closing = ('"""' if triple else '"') + ("#" * raw_hashes)
        cursor = content_start
        while cursor < length:
            if text.startswith(closing, cursor):
                yield content_start, cursor
                index = cursor + len(closing)
                break
            if not triple and raw_hashes == 0 and text[cursor] == "\\":
                cursor += 2
            else:
                cursor += 1
        else:
            # Unterminated source should be rejected by its compiler.  Scanning
            # the remaining literal is still safer than silently omitting it.
            yield content_start, length
            return


def is_scannable(path: Path, root: Path) -> bool:
    try:
        relative = path.relative_to(root)
    except ValueError:
        relative = path
    lowered_parts = tuple(part.lower() for part in relative.parts)
    if any(
        part in EXCLUDED_DIRECTORY_NAMES or part.endswith("tests")
        for part in lowered_parts[:-1]
    ):
        return False

    suffix = path.suffix.lower()
    if suffix in CODE_SUFFIXES or suffix in STRING_RESOURCE_SUFFIXES:
        return True

    # Android translatable copy lives in values*/ XML files.  Drawable/layout
    # XML is intentionally excluded to avoid treating identifiers as copy.
    if suffix == ".xml" and "res" in lowered_parts and any(
        part.startswith("values") for part in lowered_parts
    ):
        return True

    if lowered_parts and lowered_parts[0] == "marketing":
        return suffix in WEB_SUFFIXES

    if lowered_parts and lowered_parts[0] == "server" and any(
        part in {"static", "templates", "public"} for part in lowered_parts
    ):
        return suffix in WEB_SUFFIXES

    return False


def iter_scannable_files(root: Path) -> Iterator[Path]:
    if root.is_file():
        parent = root.parent
        if is_scannable(root, parent):
            yield root
        return
    for path in sorted(root.rglob("*")):
        if path.is_file() and is_scannable(path, root):
            yield path


def scan_file(path: Path) -> list[Finding]:
    text = path.read_text(encoding="utf-8")
    if path.suffix.lower() in CODE_SUFFIXES:
        findings = []
        for start, end in _code_string_spans(text):
            findings.extend(
                _scan_region(text, path=path, region_start=start, region_end=end)
            )
        return sorted(set(findings))
    return sorted(set(_scan_region(text, path=path)))


def scan(root: Path = ROOT) -> tuple[list[Finding], int]:
    findings: list[Finding] = []
    scanned = 0
    for path in iter_scannable_files(root):
        scanned += 1
        findings.extend(scan_file(path))
    return sorted(set(findings)), scanned


def run(root: Path, *, output: object = sys.stdout) -> int:
    findings, scanned = scan(root)
    if findings:
        print(
            f"health-claims gate: blocked ({len(findings)} finding(s) in "
            f"{scanned} scanned file(s))",
            file=output,
        )
        for finding in findings:
            print(finding.render(root), file=output)
        return 1
    print(
        f"health-claims gate: clear ({scanned} file(s) scanned)",
        file=output,
    )
    return 0


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--root",
        type=Path,
        default=ROOT,
        help="repository root to scan (defaults to the script's repository)",
    )
    args = parser.parse_args(argv)
    root = args.root.resolve()
    if not root.exists():
        parser.error(f"scan root does not exist: {root}")
    return run(root)


if __name__ == "__main__":
    sys.exit(main())
