import zipfile

from src.core.agent.epub_metadata import audit_metadata, finalize_metadata, read_metadata
from tests.unit.agent.epub_fixture import build_omnibus


def test_original_title_replaces_the_translated_one_in_opf_and_ncx(tmp_path):
    book = build_omnibus(tmp_path / "b.epub", 2, 1)
    finalize_metadata(book, title="Fake Saga - Volume 2", series="Fake Saga", volume=2,
                      volume_count=2, target_language="Indonesian")
    info = read_metadata(book)
    assert info["title"] == "Fake Saga - Volume 2" and info["series"] == "Fake Saga"
    assert audit_metadata(book, expect_series=True) == []


def test_attribution_is_stripped_when_asked(tmp_path):
    book = build_omnibus(tmp_path / "b.epub", 2, 1, attribution=True)
    assert "TranslateBook" in read_metadata(book)["description"]
    finalize_metadata(book, strip_attribution=True, target_language="Indonesian")
    info = read_metadata(book)
    assert info["description"] == "A tale of Aldric."
    with zipfile.ZipFile(book) as z:
        opf = z.read("OEBPS/content.opf").decode()
        assert "tbl-translator" not in opf and "tbl-attribution" not in opf
        assert "OEBPS/tbl-attribution.xhtml" not in z.namelist()
        assert z.testzip() is None


def test_attribution_is_kept_when_not_asked(tmp_path):
    book = build_omnibus(tmp_path / "b.epub", 2, 1, attribution=True)
    finalize_metadata(book, target_language="Indonesian")
    assert "TranslateBook" in read_metadata(book)["description"]
