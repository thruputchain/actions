#!/usr/bin/env bash
set -euo pipefail

cmd="${1:-}"
case "$cmd" in
  next-version)
    # next-version <OLD_X.Y.Z> <DATE_YYYYMMDD> <SHA7>
    OLD="${2:?old version required}"; DATE="${3:?date required}"; SHA="${4:?sha required}"
    IFS='.' read -r MAJ MIN PAT <<< "$OLD"
    if ! [[ "$MAJ" =~ ^[0-9]+$ && "$MIN" =~ ^[0-9]+$ && "$PAT" =~ ^[0-9]+$ ]]; then
      echo "ERROR: base version '$OLD' is not X.Y.Z" >&2
      exit 1
    fi
    echo "${MAJ}.${MIN}.$((PAT + 1))-nightly.${DATE}.g${SHA}"
    ;;
  apply)
    # apply <OLD_VERSION> <NEW_VERSION> <CARGO_TOML_PATH>
    OLD="${2:?old required}"; NEW="${3:?new required}"; FILE="${4:?file required}"
    # Escape regex metacharacters (dots) in the old version for matching.
    OLD_ESC=$(printf '%s' "$OLD" | sed 's/[.]/\\./g')
    NEW_ESC=$(printf '%s' "$NEW" | sed 's/[&/\]/\\&/g')
    # Two anchored substitutions, both keyed off the quote characters so they
    # never overlap and never touch external deps (which carry other versions):
    #   "0.17.1"   -> "<NEW>"     (the [workspace.package] version line)
    #   "=0.17.1"  -> "=<NEW>"    (every internal path-dep pin)
    # -i.bak keeps this portable across GNU and BSD sed (Linux runner / macOS test).
    sed -i.bak \
      -e "s/\"${OLD_ESC}\"/\"${NEW_ESC}\"/g" \
      -e "s/\"=${OLD_ESC}\"/\"=${NEW_ESC}\"/g" \
      "$FILE"
    rm -f "${FILE}.bak"
    ;;
  *)
    echo "usage: version.sh {next-version <old> <date> <sha> | apply <old> <new> <file>}" >&2
    exit 2
    ;;
esac
