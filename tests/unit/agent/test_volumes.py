import zipfile

from src.core.agent.volumes import split_into_volumes
from tests.unit.agent.epub_fixture import build_omnibus


def test_epub_split_per_volume(tmp_path):
    book = build_omnibus(tmp_path / "saga.epub", volumes=3, chapters=2)
    volumes = split_into_volumes(book, tmp_path / "vols")
    assert [v.label for v in volumes] == ["Volume 1", "Volume 2", "Volume 3"]

    with zipfile.ZipFile(volumes[1].path) as z:
        names = set(z.namelist())
        opf = z.read("OEBPS/content.opf").decode()
        nav = z.read("OEBPS/nav.xhtml").decode()
        ncx = z.read("OEBPS/toc.ncx").decode()
        assert z.namelist()[0] == "mimetype"
    # only volume 2's pages and its own image survive
    assert {"OEBPS/v2.xhtml", "OEBPS/v2c1.xhtml", "OEBPS/img/v2.png"} <= names
    assert not names & {"OEBPS/v1.xhtml", "OEBPS/v3c2.xhtml", "OEBPS/img/v1.png",
                        "OEBPS/img/v3.png", "OEBPS/cover.xhtml"}
    assert "v1c1" not in opf and "v3" not in opf and "Volume 2" in opf
    assert "v1.xhtml" not in nav and "v3.xhtml" not in ncx and "v2.xhtml" in nav
    # front matter (cover) stays with volume 1
    with zipfile.ZipFile(volumes[0].path) as z:
        assert "OEBPS/cover.xhtml" in z.namelist()


def test_no_markers_is_one_volume(tmp_path):
    text = tmp_path / "plain.txt"
    text.write_text("Just a story.\nNo volume markers here.\n")
    volumes = split_into_volumes(text, tmp_path / "vols")
    assert len(volumes) == 1 and volumes[0].path == text


def test_text_split_and_directory(tmp_path):
    text = tmp_path / "saga.txt"
    text.write_text("Title page\nVolume 1\nalpha\nVolume 2\nbeta\nVolume III\ngamma\n")
    volumes = split_into_volumes(text, tmp_path / "vols")
    assert [v.label for v in volumes] == ["Volume 1", "Volume 2", "Volume III"]
    assert "Title page" in volumes[0].path.read_text() and "beta" in volumes[1].path.read_text()

    folder = tmp_path / "folder"
    folder.mkdir()
    for name in ("vol10.txt", "vol2.txt", "vol1.txt"):
        (folder / name).write_text("x")
    assert [v.path.name for v in split_into_volumes(folder, tmp_path / "unused")] == \
        ["vol1.txt", "vol2.txt", "vol10.txt"]


def test_series_name_is_the_title_without_its_volume_number():
    from src.core.agent.epub_metadata import strip_volume_suffix
    assert strip_volume_suffix("Saga Palsu - Jilid 2") == "Saga Palsu"
    assert strip_volume_suffix("Saga Palsu, Volume IV") == "Saga Palsu"
    assert strip_volume_suffix("Saga Palsu") == "Saga Palsu"
    assert strip_volume_suffix("Jilid 3") == "Jilid 3"   # never empty the title
