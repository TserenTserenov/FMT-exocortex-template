#!/usr/bin/env python3
"""Event-level multiset containment check for ledger-publish.sh drain.

Byte-prefix comparison in ledger-publish.sh treats any reordering as a
conflict, even when every event in `source` is genuinely present in `dest`
(e.g. after a manual merge reordered a handful of same-timestamp events).
This checks the real invariant: source's events, compared as full canonical
records with their multiplicities, form a subset of dest's events.

Usage: ledger-event-diff.py --source-subset <source.yaml> <dest.yaml>
Exit 0  = source event multiset is contained in dest's (safe to keep dest).
Exit 1  = parse error, schema violation, or genuine containment failure —
          every non-zero exit is a caller-visible fail-closed signal.

Usage: ledger-event-diff.py --merge-driver <base> <ours> <theirs>
Git merge driver `ledger-events` for machine/ledger/** (WP-484 F157). Three-way merge of the
event multisets by full content: everything ours has, plus what theirs added since base, minus
what either side deleted since base; an event added identically by both sides counts once.
Identity rule: two events with identical full content are the same event (the same rule the
publisher's --union-merge and --source-subset use); two independent identical events cannot be
told apart and count once. Order rule: ours' events keep their order untouched; each event added
by theirs is placed after the last event whose `ts` is not later (equal `ts` goes after), scanning
from the end, so position keeps following time: readers use `events[-1]` / `reversed(events)`
(render-open.py, week-preclose-render.py), and an older event of a replayed day-close commit must
not become "the latest". An addition whose `ts` is missing or not ISO-8601 cannot be placed and
fails the merge (a visible git conflict) instead of silently becoming the last event. Event text is
copied verbatim. The result is written to <ours>; any
problem (unreadable input, header mismatch, broken invariant) exits 1 so git reports a normal
conflict. Known semantics: when both sides edit the same base event differently, both edited
versions are kept (the original is a deletion on both sides); any extra top-level header key is a
conflict until the driver learns it. It replaces the line-wise `merge=union`, which silently
interleaved neighbouring multi-line events when a day-close commit was re-applied over fresh
publications.

Usage: ledger-event-diff.py --driver-version
Prints MERGE_DRIVER_VERSION.

Usage: ledger-event-diff.py --validate <file.yaml>
Exit 0 = the file loads strictly (no duplicate keys, `events` is a list of mappings). Exit 1
otherwise. Used by ledger-publish.sh before committing and before publishing.

Usage: ledger-event-diff.py --union-merge <local.yaml> <origin.yaml>
Prints origin's events unchanged, followed by any local events missing from
origin (by full canonical content), to stdout. WP-484 пункт Y round 2
(2026-09-01, peer-session Kimi+Codex): origin's existing order is never
touched — some downstream readers use `events[-1]`/`latest wins` semantics
(confirmed live in render-open.py), so a full re-sort by timestamp could
silently change which event "wins" for them. Only append what's genuinely
new, in local's own relative order. Reuses missing_events() from
--source-subset — same identity rule (full content, not a partial
ts/source/kind key), not a second implementation of the same check. Header
fields (schema/scale/period) are validated on BOTH documents symmetrically.
Exit 1 on any mismatch (fail-closed, same as the rest of this module).
"""
import collections
import datetime
import json
import re
import sys

import yaml


# Bump on EVERY change of the driver (semantics or fix): --check compares versions only. install-ledger-merge-driver.sh never replaces an
# installed copy with an older one, so a stale worktree cannot downgrade the driver its siblings use.
MERGE_DRIVER_VERSION = 4


class DuplicateKeyLoader(yaml.SafeLoader):
    """Reject silent last-write-wins on duplicate mapping keys.

    PyYAML's SafeLoader keeps only the last value for a repeated key with no
    warning — exactly the kind of silent data loss this check exists to catch
    elsewhere in the pipeline, so the loader itself must not reintroduce it.
    """


def _construct_mapping(loader, node):
    seen = set()
    mapping = {}
    for key_node, value_node in node.value:
        key = loader.construct_object(key_node, deep=True)
        if key in seen:
            raise ValueError(f"duplicate YAML key: {key!r}")
        seen.add(key)
        mapping[key] = loader.construct_object(value_node, deep=True)
    return mapping


DuplicateKeyLoader.add_constructor(
    yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, _construct_mapping
)


def load_events(path):
    with open(path, encoding="utf-8") as fh:
        doc = yaml.load(fh, Loader=DuplicateKeyLoader)
    if not isinstance(doc, dict):
        raise ValueError(f"{path}: top-level YAML is not a mapping")
    events = doc.get("events")
    if events is None:
        raise ValueError(f"{path}: no 'events' key")
    if not isinstance(events, list):
        raise ValueError(f"{path}: 'events' is not a list")
    for i, ev in enumerate(events):
        if not isinstance(ev, dict):
            raise ValueError(f"{path}: events[{i}] is not a mapping")
    return events


def _json_default(obj):
    # ledger-append.sh always writes ts as a Python str via yaml.dump, which
    # quotes it — so PyYAML parses it back as a string, not a timestamp node.
    # This branch only matters for a hand-edited file with an unquoted
    # ISO-8601-looking ts, where PyYAML's resolver would hand back a
    # datetime. str(datetime) and the quoted-string form use different
    # separators ("2026-08-09 00:00:00+00:00" vs "2026-08-09T00:00:00Z"),
    # which would make the same logical event canonicalize differently and
    # trip a false divergence — exactly the class of bug this script exists
    # to fix. isoformat() keeps both paths converging on one representation.
    if isinstance(obj, (datetime.datetime, datetime.date)):
        return obj.isoformat()
    return str(obj)


def canonical(event):
    return json.dumps(event, sort_keys=True, ensure_ascii=False, default=_json_default)


def missing_events(source_events, dest_events):
    """Unpublished source events in source order, by full-content multiplicity."""
    remaining = collections.Counter(canonical(ev) for ev in dest_events)
    result = []
    for event in source_events:
        key = canonical(event)
        if remaining[key]:
            remaining[key] -= 1
        else:
            result.append(event)
    return result


def cmd_source_subset(source_path, dest_path):
    source_events = load_events(source_path)
    dest_events = load_events(dest_path)
    missing = missing_events(source_events, dest_events)
    if missing:
        sys.stderr.write(
            f"source has {len(missing)} event(s) not present in dest "
            f"(by full content, accounting for duplicates)\n"
        )
        return 1
    return 0


def _load_doc(path):
    with open(path, encoding="utf-8") as fh:
        return yaml.load(fh, Loader=DuplicateKeyLoader)


def _check_header(local_doc, origin_doc, names=("local", "origin")):
    for field in ("schema", "scale", "period"):
        if local_doc.get(field) != origin_doc.get(field):
            raise ValueError(
                f"header mismatch on {field!r}: {names[0]}={local_doc.get(field)!r} "
                f"{names[1]}={origin_doc.get(field)!r}"
            )
    known = {"schema", "scale", "period", "events"}
    for name, doc in zip(names, (local_doc, origin_doc)):
        extra = set(doc.keys()) - known
        if extra:
            raise ValueError(f"unexpected extra top-level keys in {name} file: {extra}")


def cmd_union_merge(local_path, origin_path):
    local_doc = _load_doc(local_path)
    origin_doc = _load_doc(origin_path)
    _check_header(local_doc, origin_doc)

    local_events = load_events(local_path)
    origin_events = load_events(origin_path)
    missing = missing_events(local_events, origin_events)

    origin_doc["events"] = origin_events + missing
    yaml.dump(origin_doc, sys.stdout, allow_unicode=True, default_flow_style=False, sort_keys=False)
    sys.stderr.write(
        f"union-merge: {len(origin_events)} origin + {len(missing)} new local "
        f"(of {len(local_events)} local total) -> {len(origin_events) + len(missing)} events\n"
    )
    return 0


def _parse_ts(value):
    """UTC datetime of an event's ts, or None when it is missing or not ISO-8601."""
    if isinstance(value, datetime.datetime):
        parsed = value
    elif isinstance(value, str):
        try:
            parsed = datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))
        except ValueError:
            return None
    else:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=datetime.timezone.utc)
    return parsed


def _split_blocks(text, path):
    """Split a ledger document into (header_text, [(canonical_key, block_text, ts), ...], footer_text).

    Event blocks are copied verbatim. Every event starts with a list item ('- ') at column 0
    (ledger-append.sh writes '- ts:', older files also have '- data:' first); the block count
    and each block's content are checked against the parsed events, so a file that is not in
    this shape is rejected instead of being merged by guesswork.
    """
    if not text.strip():
        return "", [], ""
    doc = yaml.load(text, Loader=DuplicateKeyLoader)
    if not isinstance(doc, dict):
        raise ValueError(f"{path}: top-level YAML is not a mapping")
    events = doc.get("events")
    if events is None:  # a header-only file, `events:` with nothing under it, is an empty ledger
        events = doc["events"] = []
    if not isinstance(events, list):
        raise ValueError(f"{path}: no events list")
    lines = text.splitlines(keepends=True)
    starts = [i for i, line in enumerate(lines) if line.startswith("- ")]
    if len(starts) != len(events):
        raise ValueError(f"{path}: {len(starts)} event blocks but {len(events)} parsed events")
    header = "".join(lines[: starts[0]]) if starts else text
    # A few old files keep schema/scale/period AFTER the events list: top-level keys at column 0 that
    # follow the last event are the footer, not part of that event.
    footer_start = len(lines)
    for i in range(starts[-1] + 1 if starts else len(lines), len(lines)):
        if lines[i][:1] not in ("", " ", "\t", "\n", "\r", "-", "#"):
            footer_start = i
            break
    blocks = []
    for start, end, event in zip(starts, starts[1:] + [footer_start], doc["events"]):
        block = "".join(lines[start:end])
        if not block.endswith("\n"):
            block += "\n"
        if canonical(yaml.load(block, Loader=DuplicateKeyLoader)[0]) != canonical(event):
            raise ValueError(f"{path}: block at line {start + 1} does not match its parsed event")
        blocks.append((canonical(event), block, _parse_ts(event.get("ts"))))
    return header, blocks, "".join(lines[footer_start:])


def merge_blocks(base, ours, theirs):
    """Three-way merge of event multisets; returns the merged block texts in order."""
    base_n, ours_n, theirs_n = (collections.Counter(key for key, _, _ in side) for side in (base, ours, theirs))
    target = {}
    for key in set(base_n) | set(ours_n) | set(theirs_n):
        added = max(ours_n[key] - base_n[key], theirs_n[key] - base_n[key], 0)
        deleted = max(base_n[key] - ours_n[key], base_n[key] - theirs_n[key], 0)
        if base_n[key] + added - deleted > 0:
            target[key] = base_n[key] + added - deleted
    kept, merged = collections.Counter(), []
    for key, block, ts in ours:  # ours' events keep their order
        if kept[key] < target.get(key, 0):
            kept[key] += 1
            merged.append((key, block, ts))
    for key, block, ts in theirs:  # theirs' additions go where their ts belongs
        if kept[key] < target.get(key, 0):
            kept[key] += 1
            _insert_by_ts(merged, (key, block, ts))
    if kept != collections.Counter(target):
        raise ValueError("merge invariant broken: result multiset differs from the computed target")
    return [block for _, block, _ in merged]


def _insert_by_ts(merged, item):
    """Insert after the last event that is not later than item; refuse an item without a usable ts."""
    ts = item[2]
    if ts is None:
        raise ValueError("an event added by theirs has no parseable ts and cannot be placed")
    position = len(merged)
    while position > 0 and merged[position - 1][2] is not None and merged[position - 1][2] > ts:
        position -= 1
    merged.insert(position, item)


def cmd_merge_driver(base_path, ours_path, theirs_path):
    texts = []
    for path in (base_path, ours_path, theirs_path):
        with open(path, encoding="utf-8", newline="") as fh:
            texts.append(fh.read())
    base_text, ours_text, theirs_text = texts
    docs = {name: yaml.load(text, Loader=DuplicateKeyLoader) for name, text in
            (("base", base_text), ("ours", ours_text), ("theirs", theirs_text)) if text.strip()}
    for name, doc in docs.items():
        if not isinstance(doc, dict):
            raise ValueError(f"{name}: top-level YAML is not a mapping")
    for other in ("base", "theirs"):
        if other in docs and "ours" in docs:
            _check_header(docs["ours"], docs[other], ("ours", other))
    header_ours, ours_blocks, footer_ours = _split_blocks(ours_text, "ours")
    header_theirs, theirs_blocks, footer_theirs = _split_blocks(theirs_text, "theirs")
    _, base_blocks, _ = _split_blocks(base_text, "base")
    blocks = merge_blocks(base_blocks, ours_blocks, theirs_blocks)
    header = header_ours or header_theirs
    if blocks:
        # an empty ledger written as `events: []` (ledger-append.sh does that before its first write)
        header = re.sub(r"^events:[ \t]*\[\][ \t]*$", "events:", header, flags=re.MULTILINE)
        if not header.endswith("\n"):
            header += "\n"
    merged = header + "".join(blocks) + (footer_ours or footer_theirs)
    yaml.load(merged, Loader=DuplicateKeyLoader)  # never write a file that does not load strictly
    with open(ours_path, "w", encoding="utf-8", newline="") as fh:
        fh.write(merged)
    return 0


def cmd_validate(path):
    load_events(path)
    return 0


def cmd_missing_by_field(field, source_path, dest_path):
    """Print `<field-value>\\t<canonical-json>` for each event dropped between
    source and dest, one line per missing event (dup events repeat their line).
    Used by ledger-audit-tip.sh to bucket drops by their originating `source`
    tool instead of failing on any drop — day-close and reconcile rollbacks
    legitimately shrink a ledger file, only a drop foreign to the bucket that
    published the new tip is evidence of the cross-host race WP-535 targets.
    """
    source_events = load_events(source_path)
    dest_events = load_events(dest_path)
    for ev in missing_events(source_events, dest_events):
        value = str(ev.get(field, "unknown")).replace("\t", " ")
        print(f"{value}\t{canonical(ev)}")
    return 0


def main(argv):
    if len(argv) == 4 and argv[1] == "--source-subset":
        try:
            return cmd_source_subset(argv[2], argv[3])
        except (OSError, yaml.YAMLError, ValueError) as exc:
            sys.stderr.write(f"parse error: {exc}\n")
            return 1

    if len(argv) == 5 and argv[1] == "--missing-by-field":
        try:
            return cmd_missing_by_field(argv[2], argv[3], argv[4])
        except (OSError, yaml.YAMLError, ValueError) as exc:
            sys.stderr.write(f"parse error: {exc}\n")
            return 1

    if len(argv) == 5 and argv[1] == "--merge-driver":
        try:
            return cmd_merge_driver(argv[2], argv[3], argv[4])
        except (OSError, yaml.YAMLError, ValueError) as exc:
            sys.stderr.write(f"ledger-merge-driver: {exc}\n")
            return 1

    if len(argv) == 2 and argv[1] == "--driver-version":
        print(MERGE_DRIVER_VERSION)
        return 0

    if len(argv) == 3 and argv[1] == "--validate":
        try:
            return cmd_validate(argv[2])
        except (OSError, yaml.YAMLError, ValueError) as exc:
            sys.stderr.write(f"validate error: {exc}\n")
            return 1

    if len(argv) == 4 and argv[1] == "--union-merge":
        try:
            return cmd_union_merge(argv[2], argv[3])
        except (OSError, yaml.YAMLError, ValueError) as exc:
            sys.stderr.write(f"parse error: {exc}\n")
            return 1

    sys.stderr.write(
        "usage: ledger-event-diff.py --source-subset <source.yaml> <dest.yaml>\n"
        "       ledger-event-diff.py --missing-by-field <field> <source.yaml> <dest.yaml>\n"
        "       ledger-event-diff.py --union-merge <local.yaml> <origin.yaml>\n"
        "       ledger-event-diff.py --merge-driver <base> <ours> <theirs>\n"
        "       ledger-event-diff.py --driver-version\n"
        "       ledger-event-diff.py --validate <file.yaml>\n"
    )
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
