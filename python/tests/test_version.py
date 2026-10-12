from importlib.metadata import version

import ulani_epaper


def test_package_version_matches_installed_metadata():
    # pyproject.toml and __init__.py both carry the version; keep them equal
    assert ulani_epaper.__version__ == version("ulani-epaper")
