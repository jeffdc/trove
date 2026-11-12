"""Report module — generates HTML analysis reports."""

from __future__ import annotations

import html
from dataclasses import dataclass, field
from pathlib import Path

_IMAGE_EXTENSIONS = frozenset(
    {
        ".jpg",
        ".jpeg",
        ".heic",
        ".png",
        ".tiff",
        ".tif",
        ".gif",
        ".bmp",
        ".webp",
    }
)

_CSS = """\
  body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif; margin: 2em; color: #222; background: #fafafa; }
  h1 { border-bottom: 2px solid #333; padding-bottom: 0.3em; }
  h2 { color: #555; margin-top: 2em; padding-top: 0.5em; border-top: 1px solid #ddd; }
  h3 { margin-bottom: 0.5em; }
  code { background: #eee; padding: 2px 6px; border-radius: 3px; font-size: 0.9em; }
  .group { border: 1px solid #ddd; border-radius: 6px; padding: 1em; margin-bottom: 1.5em; background: #fff; }
  .pair { display: flex; gap: 2em; flex-wrap: wrap; }
  .file-card { margin-bottom: 1em; }
  .file-card img { display: block; margin-bottom: 0.5em; border: 1px solid #ccc; border-radius: 4px; }
  .file-info { font-size: 0.9em; line-height: 1.6; }
  .file-info a { color: #0066cc; text-decoration: none; word-break: break-all; }
  .file-info a:hover { text-decoration: underline; }
  .label-library { background: #e8f5e9; color: #2e7d32; padding: 2px 8px; border-radius: 3px; font-size: 0.85em; font-weight: 600; }
  .label-kept { background: #e3f2fd; color: #1565c0; padding: 2px 8px; border-radius: 3px; font-size: 0.85em; font-weight: 600; }
  .label-skipped { background: #fff3e0; color: #e65100; padding: 2px 8px; border-radius: 3px; font-size: 0.85em; font-weight: 600; }
  .label-conflict { background: #fce4ec; color: #c62828; padding: 2px 8px; border-radius: 3px; font-size: 0.85em; font-weight: 600; }
  .summary { background: #fff; border: 1px solid #ddd; border-radius: 6px; padding: 1.5em; margin-bottom: 2em; }
  .summary a { color: #0066cc; text-decoration: none; }
  .summary a:hover { text-decoration: underline; }
  .summary table { border-collapse: collapse; }
  .summary td { padding: 4px 16px 4px 0; }
  .summary td:first-child { font-weight: 600; }
  p { color: #555; }
  .arrow { color: #999; margin: 0 0.5em; }
"""


@dataclass(frozen=True)
class FileInfo:
    """Info about a single file for report rendering."""

    path: str
    size: int
    capture_date: str | None = None
    camera_model: str | None = None
    is_library: bool = False
    label: str | None = None  # "kept", "skipped", "in library", "conflict: renamed to ..."
    target_path: str | None = None  # for files being imported or with path conflicts


@dataclass(frozen=True)
class DuplicateGroup:
    """A group of files that share the same content hash."""

    md5_hash: str
    files: list[dict] = field(default_factory=list)


def _is_image(path: str) -> bool:
    return Path(path).suffix.lower() in _IMAGE_EXTENSIONS


def _human_size(size_bytes: int) -> str:
    if size_bytes >= 1024 * 1024:
        return f"{size_bytes / (1024 * 1024):.1f} MB"
    return f"{size_bytes / 1024:.1f} KB"


def _render_file_card(f: FileInfo | dict) -> str:
    """Render a single file as an HTML card."""
    if isinstance(f, dict):
        # Backward compat with DuplicateGroup dicts
        path = f["path"]
        size = f["size"]
        capture_date = f.get("capture_date")
        camera_model = f.get("camera_model")
        is_library = f.get("is_library", False)
        label = f.get("label")
        target_path = f.get("target_path")
    else:
        path = f.path
        size = f.size
        capture_date = f.capture_date
        camera_model = f.camera_model
        is_library = f.is_library
        label = f.label
        target_path = f.target_path

    escaped_path = html.escape(path)
    file_url = f"file://{escaped_path}"
    size_str = _human_size(size)

    label_html = ""
    if is_library:
        label_html = ' <span class="label-library">(in library)</span>'
    elif label:
        css_class = (
            "label-kept"
            if "kept" in label.lower()
            else ("label-conflict" if "conflict" in label.lower() or "renamed" in label.lower() else "label-skipped")
        )
        label_html = f' <span class="{css_class}">({html.escape(label)})</span>'

    lines = ['<div class="file-card">']

    if _is_image(path):
        lines.append(
            f'  <a href="{file_url}">'
            f'<img src="{file_url}" style="max-height: 200px; max-width: 300px;" loading="lazy">'
            f"</a>"
        )

    lines.append('  <div class="file-info">')
    lines.append(f'    <a href="{file_url}">{escaped_path}</a>{label_html}')
    lines.append(f"    <br>{size_str}")
    if capture_date:
        lines.append(f"    <br>Date: {html.escape(str(capture_date))}")
    if camera_model:
        lines.append(f"    <br>Camera: {html.escape(str(camera_model))}")
    if target_path:
        lines.append(f'    <br><span class="arrow">&rarr;</span> {html.escape(target_path)}')
    lines.append("  </div>")
    lines.append("</div>")
    return "\n".join(lines)


def _render_group(group: DuplicateGroup, index: int) -> str:
    lines = ['<div class="group">']
    lines.append(f"  <h3>Group {index} &mdash; hash: <code>{html.escape(group.md5_hash)}</code></h3>")

    if len(group.files) == 2:
        lines.append('  <div class="pair">')
        for f in group.files:
            lines.append(_render_file_card(f))
        lines.append("  </div>")
    else:
        for f in group.files:
            lines.append(_render_file_card(f))

    lines.append("</div>")
    return "\n".join(lines)


def generate_analysis_report(
    to_import: list[FileInfo],
    path_conflicts: list[FileInfo],
    library_duplicates: list[DuplicateGroup],
    batch_duplicates: list[DuplicateGroup],
    quarantined: list[FileInfo],
    output_path: Path,
    library_name: str,
    source_path: str,
) -> None:
    """Generate a full HTML analysis report.

    Covers all categories: files to import, path conflicts, library duplicates,
    batch duplicates, and quarantined files. Each section has an anchor link
    from the summary at the top.
    """
    body = []

    # Title
    body.append(f"<h1>Trove Analysis Report &mdash; {html.escape(library_name)}</h1>")
    body.append(f"<p>Source: <code>{html.escape(source_path)}</code></p>")

    # Summary with anchor links
    total = len(to_import) + len(path_conflicts) + len(quarantined)
    for g in library_duplicates:
        total += (
            len(
                [f for f in g.files if not f.get("is_library", False) if isinstance(f, dict)]
                if isinstance(g.files[0], dict)
                else 1
            )
            if g.files
            else 0
        )
    for g in batch_duplicates:
        total += len(g.files)

    body.append('<div class="summary">')
    body.append('<h2 style="border: none; margin-top: 0; padding-top: 0;">Summary</h2>')
    body.append("<table>")
    if to_import:
        body.append(f'<tr><td><a href="#import">Files to import</a></td><td>{len(to_import)}</td></tr>')
    if path_conflicts:
        body.append(
            f'<tr><td><a href="#conflicts">Path conflicts (auto-resolved)</a></td><td>{len(path_conflicts)}</td></tr>'
        )
    if library_duplicates:
        lib_dup_count = sum(
            len([f for f in g.files if not (f.get("is_library") if isinstance(f, dict) else False)])
            for g in library_duplicates
        )
        body.append(f'<tr><td><a href="#library-dupes">Already in library</a></td><td>{lib_dup_count}</td></tr>')
    if batch_duplicates:
        batch_dup_count = sum(len(g.files) for g in batch_duplicates) - len(batch_duplicates)  # subtract keepers
        body.append(f'<tr><td><a href="#batch-dupes">Duplicates in source</a></td><td>{batch_dup_count}</td></tr>')
    if quarantined:
        body.append(f'<tr><td><a href="#quarantined">Quarantined (no date)</a></td><td>{len(quarantined)}</td></tr>')
    body.append("</table>")
    body.append("</div>")

    # Section 1: Files to Import
    body.append('<h2 id="import">Files to Import</h2>')
    if not to_import:
        body.append("<p>None — all files are duplicates or quarantined.</p>")
    else:
        body.append(f"<p>{len(to_import)} file(s) will be copied to the library.</p>")
        for f in to_import:
            body.append('<div class="group">')
            body.append(_render_file_card(f))
            body.append("</div>")

    # Section 2: Path Conflicts
    body.append('<h2 id="conflicts">Path Conflicts (Auto-Resolved)</h2>')
    if not path_conflicts:
        body.append("<p>None.</p>")
    else:
        body.append(f"<p>{len(path_conflicts)} file(s) had target path conflicts and were renamed.</p>")
        for f in path_conflicts:
            body.append('<div class="group">')
            body.append(_render_file_card(f))
            body.append("</div>")

    # Section 3: Already in Library
    body.append('<h2 id="library-dupes">Already in Library</h2>')
    if not library_duplicates:
        body.append("<p>None.</p>")
    else:
        body.append(
            f"<p>{len(library_duplicates)} group(s) — source files that match existing library entries by content.</p>"
        )
        for i, group in enumerate(library_duplicates, 1):
            body.append(_render_group(group, i))

    # Section 4: Duplicates in Source
    body.append('<h2 id="batch-dupes">Duplicates in Source</h2>')
    if not batch_duplicates:
        body.append("<p>None.</p>")
    else:
        body.append(f"<p>{len(batch_duplicates)} group(s) — files within the source that share identical content.</p>")
        for i, group in enumerate(batch_duplicates, 1):
            body.append(_render_group(group, i))

    # Section 5: Quarantined
    body.append('<h2 id="quarantined">Quarantined (No Date)</h2>')
    if not quarantined:
        body.append("<p>None.</p>")
    else:
        body.append(f"<p>{len(quarantined)} file(s) with no date information.</p>")
        for f in quarantined:
            body.append('<div class="group">')
            body.append(_render_file_card(f))
            body.append("</div>")

    content = f"""\
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Trove Analysis Report — {html.escape(library_name)}</title>
<style>
{_CSS}
</style>
</head>
<body>
{chr(10).join(body)}
</body>
</html>
"""

    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(content)


# Keep backward compat for existing callers
def generate_duplicate_report(
    batch_groups: list[DuplicateGroup],
    library_groups: list[DuplicateGroup],
    output_path: Path,
    library_name: str,
) -> None:
    """Generate an HTML report of duplicate files (legacy wrapper)."""
    generate_analysis_report(
        to_import=[],
        path_conflicts=[],
        library_duplicates=library_groups,
        batch_duplicates=batch_groups,
        quarantined=[],
        output_path=output_path,
        library_name=library_name,
        source_path="",
    )
