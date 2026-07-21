# Architecture and review-size standards

This repository is a KOReader adaptation, not a second system manager. It owns
KOReader-specific launch preparation, data migration, library indexing, and the
small lifecycle user patch. Display ownership, raw input, foreground leases,
and process supervision belong to Remagic.

- Production files target at most 400 physical lines and fail above 500 by
  default. A cohesive adapter that is clearer intact may use one exact-path,
  reasoned limit in `architecture-exceptions.tsv`; no globs or directory-wide
  exemptions are accepted.
- Tests and fixtures may contain up to 800 lines.
- Vendored KOReader code and upstream patch payloads remain isolated and are
  excluded from this repository's local-size gate.
- Each script or Lua module has one operational responsibility; shared protocol
  parsing and migration rules are extracted instead of copied.

Run `scripts/check-architecture.sh` together with `scripts/check.sh` before a
release. A line-count pass never substitutes for responsibility review, and an
exception is removed once its architectural reason disappears.
