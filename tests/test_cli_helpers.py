"""Tests for the cli_helpers module — library lookup and prompt helpers."""

from __future__ import annotations


class TestResolveLibrary:
    def test_name_found(self, db, library):
        """Library name returns the library."""
        from trove.cli_helpers import resolve_library

        result = resolve_library(db, library.name)
        assert result is not None
        assert result.name == library.name

    def test_name_not_found(self, db):
        """Name that doesn't exist returns None."""
        from trove.cli_helpers import resolve_library

        result = resolve_library(db, "nonexistent")
        assert result is None


class TestPathCompletionMatches:
    def test_completes_relative_paths(self, tmp_path, monkeypatch):
        """Relative prompt input returns matching entries in the current directory."""
        from trove.cli_helpers import get_path_completion_matches

        monkeypatch.chdir(tmp_path)
        (tmp_path / "photos").mkdir()
        (tmp_path / "photoshoot").mkdir()
        (tmp_path / "video.mp4").write_text("x")

        matches = get_path_completion_matches("pho")

        assert matches == ["photos/", "photoshoot/"]

    def test_completes_absolute_paths(self, tmp_path):
        """Absolute prompt input preserves the absolute path prefix."""
        from trove.cli_helpers import get_path_completion_matches

        base = tmp_path / "imports"
        base.mkdir()
        (base / "trip").mkdir()

        matches = get_path_completion_matches(str(base / "tr"))

        assert matches == [str(base / "trip") + "/"]

    def test_lists_directory_contents_when_prefix_ends_with_separator(self, tmp_path):
        """Directory prompts with a trailing separator list that directory's contents."""
        from trove.cli_helpers import get_path_completion_matches

        base = tmp_path / "library"
        base.mkdir()
        (base / "2024").mkdir()
        (base / "cover.jpg").write_text("x")

        matches = get_path_completion_matches(str(base) + "/")

        assert matches == [str(base / "2024") + "/", str(base / "cover.jpg")]


class TestReadlineBindings:
    def test_uses_libedit_binding_when_needed(self, monkeypatch):
        """macOS libedit needs a different parse_and_bind command for Tab."""
        from trove import cli_helpers

        fake_readline = type("FakeReadline", (), {"__doc__": "Importing this module enables command line editing using libedit readline."})()
        monkeypatch.setattr(cli_helpers, "readline", fake_readline)

        assert cli_helpers._readline_tab_binding() == "bind ^I rl_complete"

    def test_uses_gnu_readline_binding_otherwise(self, monkeypatch):
        """GNU readline uses the standard tab binding syntax."""
        from trove import cli_helpers

        fake_readline = type("FakeReadline", (), {"__doc__": "GNU readline support"})()
        monkeypatch.setattr(cli_helpers, "readline", fake_readline)

        assert cli_helpers._readline_tab_binding() == "tab: complete"
