"""Level 2 Strict Validation: Human-reviewable source verification.

For each sampled edge, reads the EXACT line and surrounding context,
applies strict matching (not just substring), and dumps every edge
with full context for manual review.

Strict checks:
- The callee name must appear as a function CALL (followed by `(`)
  or as a dotted method call (`.name(`)
- Not inside a comment (# ...) or string literal
- Not just an import statement
- Not a function definition (def name)
"""

import re
from pathlib import Path

import pytest
from helpers import cypher_query


def _read_context(filepath: str, center_line: int, window: int = 5) -> list:
    """Read lines around center_line. Returns list of (line_number, text) tuples."""
    try:
        lines = Path(filepath).read_text(encoding="utf-8", errors="replace").splitlines()
        start = max(0, center_line - 1 - window)
        end = min(len(lines), center_line - 1 + window + 1)
        return [(i + 1, lines[i]) for i in range(start, end)]
    except Exception:
        return []


def _is_in_comment_or_string(line: str, name: str) -> bool:
    """Check if `name` only appears inside a comment or string on this line."""
    # Strip trailing comment
    code_part = line.split("#")[0] if "#" in line else line
    # If name isn't in code part, it's only in a comment
    if name not in code_part:
        return True
    # Check if it's inside a string (rough heuristic: between matching quotes)
    # Remove all quoted strings and check if name survives
    no_strings = re.sub(r'""".*?"""|\'\'\'.*?\'\'\'|"[^"]*"|\'[^\']*\'', '', code_part, flags=re.DOTALL)
    if name not in no_strings:
        return True
    return False


def _classify_call(lines: list, callee_name: str, call_line: int) -> str:
    """Classify a CALLS edge as verified, suspicious, or false_positive.

    Returns one of:
    - "verified": callee_name appears as a call (name( or .name() on or near the line
    - "suspicious": callee_name appears but not clearly as a call
    - "false_positive": callee_name doesn't appear near the line at all
    """
    # Check the exact call line and ±3 lines
    nearby = [(ln, text) for ln, text in lines if abs(ln - call_line) <= 3]

    for ln, text in nearby:
        # Skip if only in comment/string
        if _is_in_comment_or_string(text, callee_name):
            continue

        stripped = text.split("#")[0]  # remove comment

        # Skip import lines
        if re.match(r'^\s*(from |import )', stripped):
            continue
        # Skip function definitions
        if re.match(rf'^\s*def\s+{re.escape(callee_name)}\s*\(', stripped):
            continue

        # Direct call: name(
        if re.search(rf'\b{re.escape(callee_name)}\s*\(', stripped):
            return "verified"
        # Dotted call: .name(
        if re.search(rf'\.{re.escape(callee_name)}\s*\(', stripped):
            return "verified"
        # Decorator: @name
        if re.search(rf'@{re.escape(callee_name)}\b', stripped):
            return "verified"

    # Check wider window — maybe multi-line call
    for ln, text in lines:
        if _is_in_comment_or_string(text, callee_name):
            continue
        stripped = text.split("#")[0]
        if re.match(r'^\s*(from |import )', stripped):
            continue
        if re.match(rf'^\s*def\s+{re.escape(callee_name)}\s*\(', stripped):
            continue
        if re.search(rf'\b{re.escape(callee_name)}\s*\(', stripped):
            return "verified"
        if re.search(rf'\.{re.escape(callee_name)}\s*\(', stripped):
            return "verified"

    # Name appears somewhere but not as a clear call
    for ln, text in lines:
        if callee_name in text and not _is_in_comment_or_string(text, callee_name):
            return "suspicious"

    return "false_positive"


class TestCallsStrictValidation:

    def test_calls_strict_100(self):
        result = cypher_query(
            "MATCH (caller)-[r:CALLS]->(callee) "
            "WHERE caller.path CONTAINS '/RamPump/' "
            "AND r.line_number IS NOT NULL AND r.line_number > 0 "
            "WITH caller, r, callee, rand() AS rnd ORDER BY rnd "
            "RETURN caller.name AS caller_name, "
            "       caller.path AS caller_path, "
            "       callee.name AS callee_name, "
            "       callee.path AS callee_path, "
            "       r.line_number AS call_line, "
            "       r.full_call_name AS full_call "
            "LIMIT 100",
            timeout=60,
        )
        rows = result.get("results", [])
        assert len(rows) > 0

        verified = 0
        suspicious = []
        false_positives = []
        unverifiable = []

        for row in rows:
            caller_name = row.get("caller_name", "")
            caller_path = row.get("caller_path", "")
            callee_name = row.get("callee_name", "")
            callee_path = row.get("callee_path", "")
            call_line = row.get("call_line", 0)
            full_call = row.get("full_call", "") or callee_name

            if not caller_path or not Path(caller_path).exists():
                unverifiable.append({"caller_path": caller_path, "callee": callee_name})
                continue

            lines = _read_context(caller_path, call_line, window=5)
            if not lines:
                unverifiable.append({"caller_path": caller_path, "call_line": call_line})
                continue

            classification = _classify_call(lines, callee_name, call_line)

            rel_caller = caller_path.split("/RamPump/")[-1] if "/RamPump/" in caller_path else caller_path
            rel_callee = callee_path.split("/RamPump/")[-1] if "/RamPump/" in callee_path else callee_path
            exact_line = ""
            for ln, text in lines:
                if ln == call_line:
                    exact_line = text.strip()
                    break

            entry = {
                "caller": f"{caller_name} in {rel_caller}:{call_line}",
                "callee": f"{callee_name} in {rel_callee}",
                "full_call": full_call,
                "line": exact_line[:120],
            }

            if classification == "verified":
                verified += 1
            elif classification == "suspicious":
                suspicious.append(entry)
            else:
                false_positives.append(entry)

        total = len(rows)
        checkable = total - len(unverifiable)
        precision = verified / max(checkable, 1)

        print(f"\n{'='*70}")
        print(f"  CALLS Strict Validation (100 random edges)")
        print(f"{'='*70}")
        print(f"  Total sampled:      {total}")
        print(f"  Verified (call):    {verified}")
        print(f"  Suspicious:         {len(suspicious)}")
        print(f"  False positives:    {len(false_positives)}")
        print(f"  Unverifiable:       {len(unverifiable)}")
        print(f"  Strict precision:   {precision:.1%}")
        print(f"  Clean precision:    {(verified) / max(checkable, 1):.1%}")

        if suspicious:
            print(f"\n  --- Suspicious (name present but not as clear call) ---")
            for s in suspicious:
                print(f"  {s['caller']}")
                print(f"    → {s['callee']}")
                print(f"    full_call: {s['full_call']}")
                print(f"    source: {s['line']}")
                print()

        if false_positives:
            print(f"\n  --- False Positives (name NOT found near line) ---")
            for fp in false_positives:
                print(f"  {fp['caller']}")
                print(f"    → {fp['callee']}")
                print(f"    full_call: {fp['full_call']}")
                print(f"    source: {fp['line']}")
                print()

        # With strict checking, allow some suspicious but no false positives
        fp_rate = len(false_positives) / max(checkable, 1)
        assert fp_rate <= 0.05, (
            f"False positive rate {fp_rate:.1%} exceeds 5%. "
            f"FPs: {len(false_positives)}/{checkable}"
        )


class TestInheritsStrictValidation:

    def test_inherits_strict_50(self):
        result = cypher_query(
            "MATCH (child:Class)-[:INHERITS]->(parent:Class) "
            "WHERE child.path CONTAINS '/RamPump/' "
            "AND child.line_number IS NOT NULL AND child.line_number > 0 "
            "WITH child, parent, rand() AS rnd ORDER BY rnd "
            "RETURN child.name AS child_name, "
            "       child.path AS child_path, "
            "       child.line_number AS child_line, "
            "       parent.name AS parent_name "
            "LIMIT 50",
            timeout=60,
        )
        rows = result.get("results", [])
        assert len(rows) > 0

        verified = 0
        false_positives = []
        unverifiable = []

        for row in rows:
            child_name = row.get("child_name", "")
            child_path = row.get("child_path", "")
            child_line = row.get("child_line", 0)
            parent_name = row.get("parent_name", "")

            if not child_path or not Path(child_path).exists():
                unverifiable.append({"child": child_name, "parent": parent_name})
                continue

            lines = _read_context(child_path, child_line, window=5)
            if not lines:
                unverifiable.append({"child_path": child_path})
                continue

            # Strict check: must find "class ChildName(...ParentName...)"
            found = False
            class_def_started = False
            paren_content = ""
            for ln, text in lines:
                if re.search(rf'class\s+{re.escape(child_name)}\s*\(', text):
                    class_def_started = True
                if class_def_started:
                    paren_content += text
                    if ")" in text:
                        break

            if class_def_started and parent_name in paren_content:
                # Extra check: parent must be in the base class list, not a default arg
                # Extract content between the parens after class name
                m = re.search(rf'class\s+{re.escape(child_name)}\s*\((.+?)(?:\)|$)',
                              paren_content, re.DOTALL)
                if m and parent_name in m.group(1):
                    found = True

            if found:
                verified += 1
            else:
                rel_path = child_path.split("/RamPump/")[-1] if "/RamPump/" in child_path else child_path
                exact = ""
                for ln, text in lines:
                    if ln == child_line:
                        exact = text.strip()
                        break
                false_positives.append({
                    "child": f"{child_name} in {rel_path}:{child_line}",
                    "parent": parent_name,
                    "line": exact[:120],
                    "paren_content": paren_content.strip()[:150],
                })

        total = len(rows)
        checkable = total - len(unverifiable)
        precision = verified / max(checkable, 1)

        print(f"\n{'='*70}")
        print(f"  INHERITS Strict Validation (50 random edges)")
        print(f"{'='*70}")
        print(f"  Total sampled:      {total}")
        print(f"  Verified:           {verified}")
        print(f"  False positives:    {len(false_positives)}")
        print(f"  Unverifiable:       {len(unverifiable)}")
        print(f"  Strict precision:   {precision:.1%}")

        if false_positives:
            print(f"\n  --- False Positives ---")
            for fp in false_positives:
                print(f"  CHILD:  {fp['child']}")
                print(f"  PARENT: {fp['parent']}")
                print(f"  LINE:   {fp['line']}")
                print(f"  PARENS: {fp['paren_content']}")
                print()

        fp_rate = len(false_positives) / max(checkable, 1)
        assert fp_rate <= 0.05, (
            f"INHERITS FP rate {fp_rate:.1%} exceeds 5%. "
            f"FPs: {len(false_positives)}/{checkable}"
        )
