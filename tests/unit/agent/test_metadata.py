import zipfile

from src.core.agent.epub_metadata import audit_metadata, edit_field, finalize_metadata, read_metadata
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


def test_edit_field_sets_and_clears_one_field(tmp_path):
    book = build_omnibus(tmp_path / "b.epub", 2, 1)
    edit_field(book, "description", "Sebuah kisah.")
    edit_field(book, "publisher", "Penerbit Contoh")
    assert read_metadata(book)["description"] == "Sebuah kisah."
    edit_field(book, "description", "")
    assert read_metadata(book)["description"] == ""
    edit_field(book, "series", "Saga Aldric", volume=2, volume_count=2)
    assert read_metadata(book)["series"] == "Saga Aldric"
    edit_field(book, "title", "Judul Baru")
    assert read_metadata(book)["title"] == "Judul Baru"
    try:
        edit_field(book, "nonsense", "x")
    except ValueError:
        pass
    else:
        raise AssertionError("unknown field accepted")


def test_isbn_and_cover_can_be_added(tmp_path):
    book = build_omnibus(tmp_path / "b.epub", 1, 1)
    edit_field(book, "isbn", "978-0-14-043787-7")
    edit_field(book, "isbn", "9780140437877")   # not added twice
    with zipfile.ZipFile(book) as z:
        opf = z.read("OEBPS/content.opf").decode()
    assert opf.count("urn:isbn:9780140437877") == 1
    image = tmp_path / "c.png"
    image.write_bytes(b"\x89PNG\r\n\x1a\n" + b"0" * 20)
    edit_field(book, "cover", str(image))
    with zipfile.ZipFile(book) as z:
        opf = z.read("OEBPS/content.opf").decode()
        assert "OEBPS/cover-online.png" in z.namelist()
    assert opf.count('properties="cover-image"') == 1 and 'content="cover-online"' in opf
    assert audit_metadata(book) == [] or "cover" not in " ".join(audit_metadata(book))


def test_several_subjects_separated_by_a_bar(tmp_path):
    book = build_omnibus(tmp_path / "b.epub", 1, 1)
    edit_field(book, "subject", "Mystery|Detective fiction")
    assert read_metadata(book)["subjects"] == ["Mystery", "Detective fiction"]
