from trove.config import LibraryConfig, OrganizationConfig


class TestLibraryConfigDefaults:
    """LibraryConfig() with no args gives sensible defaults."""

    def test_default_organization(self):
        config = LibraryConfig()
        assert config.organization.structure == "%Y/%m"
        assert config.organization.include_camera_model is True
        assert config.organization.unknown_model_label == "Unknown_Model"

    def test_default_file_types(self):
        config = LibraryConfig()
        assert "jpg" in config.file_types.photos
        assert "mov" in config.file_types.videos
        assert "cr2" in config.file_types.raw

    def test_default_exclude_patterns(self):
        config = LibraryConfig()
        assert "*.DS_Store" in config.exclude_patterns

    def test_default_quarantine(self):
        config = LibraryConfig()
        assert config.quarantine.path == "quarantine/"
        assert "no_exif_date" in config.quarantine.reasons


class TestLibraryConfigJsonRoundTrip:
    """LibraryConfig serializes to JSON and deserializes back identically."""

    def test_defaults_round_trip(self):
        config = LibraryConfig()
        json_str = config.to_json()
        restored = LibraryConfig.from_json(json_str)
        assert restored == config

    def test_custom_org_round_trip(self):
        config = LibraryConfig(
            organization=OrganizationConfig(structure="%Y/%m/%d", include_camera_model=False)
        )
        restored = LibraryConfig.from_json(config.to_json())
        assert restored.organization.structure == "%Y/%m/%d"
        assert restored.organization.include_camera_model is False

    def test_from_empty_json(self):
        """Empty JSON object gives defaults."""
        config = LibraryConfig.from_json("{}")
        assert config == LibraryConfig()

    def test_from_partial_json(self):
        """JSON with only organization overrides, rest defaults."""
        config = LibraryConfig.from_json('{"organization": {"structure": "%Y"}}')
        assert config.organization.structure == "%Y"
        assert config.organization.include_camera_model is True  # default
        assert "jpg" in config.file_types.photos  # default
