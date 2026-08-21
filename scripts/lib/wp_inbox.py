"""WP inbox card discovery (WP-434 convention: one WP = one folder).

A WP card lives at the canonical folder path ``inbox/WP-N/WP-N.md`` or, for
legacy/transition stragglers, as a flat file ``inbox/WP-N*.md``. Readers that
scan the inbox for WP frontmatter must look at BOTH levels — a flat-only glob
silently drops folder cards (the regression that hid WP-426 from
active-wp-sweep and zeroed Day Open WP facts after the WP-434 migration).

Single source for this two-level traversal so every reader stays consistent.
"""

import glob
import os


def wp_card_paths(base_dir):
    """Paths of WP card files under ``base_dir`` — flat plus folder-canonical.

    - Flat: ``base_dir/WP-*.md`` (legacy cards and non-numbered WP-INCIDENT-* ).
    - Folder: ``base_dir/WP-N/WP-N.md`` — the canonical main file only, never
      sub-files inside the folder.

    Returns a list of string paths (callers wrap in ``pathlib.Path`` as needed).
    """
    paths = glob.glob(os.path.join(base_dir, "WP-*.md"))
    for folder in glob.glob(os.path.join(base_dir, "WP-*", "")):
        name = os.path.basename(os.path.normpath(folder))  # "WP-7"
        main = os.path.join(folder, name + ".md")
        if os.path.isfile(main):
            paths.append(main)
    return paths
