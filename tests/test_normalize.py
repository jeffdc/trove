from __future__ import annotations

from trove.normalize import normalize_filename


class TestNormalizeFilename:
    def test_clean_filename_unchanged(self):
        """Clean filename passes through unchanged."""
        assert normalize_filename("IMG_0042.JPG") == "IMG_0042.JPG"

    def test_spaces_become_underscores(self):
        """Spaces replaced with underscores."""
        assert normalize_filename("my photo.jpg") == "my_photo.jpg"

    def test_tabs_become_underscores(self):
        """Tab characters replaced with underscores."""
        assert normalize_filename("file\tname.jpg") == "file_name.jpg"

    def test_path_unsafe_chars_replaced(self):
        """Path-unsafe characters replaced with underscores."""
        assert normalize_filename("file/name:bad*.jpg") == "file_name_bad.jpg"

    def test_multiple_underscores_collapsed(self):
        """Multiple consecutive underscores collapsed to one."""
        assert normalize_filename("a___b.jpg") == "a_b.jpg"

    def test_leading_trailing_dots_stripped(self):
        """Leading/trailing dots stripped from basename."""
        assert normalize_filename("..hidden.jpg") == "hidden.jpg"

    def test_leading_trailing_underscores_stripped(self):
        """Leading/trailing underscores stripped from basename."""
        assert normalize_filename("__file__.jpg") == "file.jpg"

    def test_empty_basename_becomes_unnamed(self):
        """When basename is empty after sanitization, use 'unnamed'."""
        assert normalize_filename(".jpg") == "unnamed.jpg"
        assert normalize_filename("....jpg") == "unnamed.jpg"
        assert normalize_filename("___.jpg") == "unnamed.jpg"

    def test_long_filename_truncated_with_hash(self):
        """Filename >200 chars truncated with hash suffix for uniqueness."""
        long_name = "a" * 250 + ".jpg"
        result = normalize_filename(long_name)
        basename, ext = result.rsplit(".", 1)
        assert ext == "jpg"
        assert len(basename) <= 200
        assert "_" in basename  # has hash suffix
        # Two different long names produce different results
        long_name2 = "b" * 250 + ".jpg"
        result2 = normalize_filename(long_name2)
        assert result != result2

    def test_camera_model_sanitized(self):
        """Camera model string (no extension) sanitized."""
        assert normalize_filename("Canon EOS R5") == "Canon_EOS_R5"

    def test_camera_model_with_slashes(self):
        """Slashes in camera model replaced."""
        assert normalize_filename("Apple iPhone 15 Pro/Back Camera") == "Apple_iPhone_15_Pro_Back_Camera"

    def test_unicode_nfc_normalized(self):
        """Unicode composed and decomposed forms produce same result."""
        # é as single char (NFC) vs e + combining accent (NFD)
        composed = "caf\u00e9.jpg"
        decomposed = "cafe\u0301.jpg"
        assert normalize_filename(composed) == normalize_filename(decomposed)

    def test_no_extension(self):
        """Filename with no extension preserved as-is."""
        assert normalize_filename("README") == "README"

    def test_windows_reserved_names_prefixed(self):
        """Windows reserved names get prefixed with underscore."""
        assert normalize_filename("CON.jpg") == "_CON.jpg"
        assert normalize_filename("prn.txt") == "_prn.txt"
        assert normalize_filename("NUL.jpg") == "_NUL.jpg"
        assert normalize_filename("COM1.jpg") == "_COM1.jpg"
        assert normalize_filename("LPT9.txt") == "_LPT9.txt"
        assert normalize_filename("AUX") == "_AUX"

    def test_windows_reserved_case_preserved(self):
        """Windows reserved name check is case-insensitive but preserves case."""
        assert normalize_filename("con.jpg") == "_con.jpg"
        assert normalize_filename("Con.jpg") == "_Con.jpg"

    def test_not_reserved_if_has_extra_chars(self):
        """CONX.jpg is not a reserved name, should not be prefixed."""
        assert normalize_filename("CONX.jpg") == "CONX.jpg"
        assert normalize_filename("CONNECT.jpg") == "CONNECT.jpg"
