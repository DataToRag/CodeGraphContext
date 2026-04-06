from pathlib import Path

from codegraphcontext.core.cgcignore import (
    build_ignore_spec,
    parse_cgcignore_lines,
)


def test_parse_cgcignore_lines_skips_comments_and_blanks():
    lines = [
        "",
        "   ",
        "# comment",
        "  # spaced comment",
        "*.txt",
        " *.json ",
    ]

    assert parse_cgcignore_lines(lines) == ["*.txt", "*.json"]


def test_build_ignore_spec_merges_default_and_user_patterns(tmp_path: Path):
    repo = tmp_path / "repo"
    repo.mkdir()
    cgcignore = repo / ".cgcignore"
    cgcignore.write_text("# only ignore text\n*.txt\n\n*.log\n", encoding="utf-8")

    default_patterns = ["*.png", "*.mp4"]
    spec, resolved = build_ignore_spec(ignore_root=repo, default_patterns=default_patterns)

    assert resolved == cgcignore
    assert spec.match_file("assets/icon.png")
    assert spec.match_file("logs/debug.log")
    assert spec.match_file("notes.txt")
    assert not spec.match_file("src/main.py")
    assert not spec.match_file("config.json")


def test_build_ignore_spec_auto_creates_cgcignore_with_defaults(tmp_path: Path):
    repo = tmp_path / "repo"
    repo.mkdir()

    default_patterns = ["*.png", "*.zip"]
    spec, resolved = build_ignore_spec(ignore_root=repo, default_patterns=default_patterns)

    assert resolved == repo / ".cgcignore"
    assert resolved.exists()

    content = resolved.read_text(encoding="utf-8")
    assert "*.png" in content
    assert "*.zip" in content

    assert spec.match_file("image.png")
    assert spec.match_file("archives/data.zip")
    assert not spec.match_file("src/main.py")
