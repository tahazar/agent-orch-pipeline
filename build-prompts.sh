#!/bin/bash
# build-prompts.sh - assemble role prompts and render per-role settings.
#
# Prompts are layered so the shared protocol stays single-sourced:
#
#   1. context/identity/<role>.md        identity + INVARIANTS  (all roles)
#   2. context/workflow.md               shared protocol        (all roles)
#   3. context/workflow-coordination.md  coordination           (conductor/arbiter/foreman ONLY)
#   4. context/playbook-*.md             the three playbooks    (foreman + workers)
#   5. context/<role>-role.md            phase-by-phase protocol (all roles)
#
# Workers must NOT receive the coordination layer. `<!-- layer: NAME -->`
# markers are emitted so test/prompt-lint.sh can assert the layering.
#
# Settings templates are rendered here too, because their hook commands need
# this checkout's absolute path.

set -u

HERE="$(cd -P "$(dirname "$0")" && pwd)"
CONTEXT="$HERE/context"
OUT="$HERE/prompts"
SETTINGS="$HERE/settings"

ROLES="conductor arbiter foreman prover inspector builder"
COORDINATORS="conductor arbiter foreman"
PLAYBOOK_ROLES="foreman prover inspector builder"

errors=0

fail() { printf 'build-prompts: %s\n' "$*" >&2; errors=$((errors + 1)); }

is_in_list() {
  local needle="$1" item
  shift
  for item in $1; do
    [ "$item" = "$needle" ] && return 0
  done
  return 1
}

emit_layer() {
  local name="$1" file="$2" out="$3"
  if [ ! -f "$file" ]; then
    fail "missing layer file: $file"
    return 1
  fi
  {
    printf '\n<!-- layer: %s -->\n\n' "$name"
    cat "$file"
    printf '\n'
  } >> "$out"
}

mkdir -p "$OUT" || exit 1

# Prune artifacts left behind by a role that no longer exists, so a rename
# cannot leave a stale prompt or settings file sitting next to the real ones.
prune_orphans() {
  local dir="$1" pattern="$2" strip_prefix="$3" strip_suffix="$4" f name
  for f in "$dir"/$pattern; do
    [ -e "$f" ] || continue
    name="$(basename "$f")"
    name="${name#$strip_prefix}"
    name="${name%$strip_suffix}"
    case " $ROLES " in
      *" $name "*) ;;
      *) rm -f "$f"; printf 'pruned %s (no such role)\n' "$(basename "$f")" ;;
    esac
  done
}
prune_orphans "$OUT" '*.md' '' '.md'
prune_orphans "$SETTINGS" 'role-*.json' 'role-' '.json'

for role in $ROLES; do
  out="$OUT/$role.md"
  : > "$out"

  emit_layer "identity" "$CONTEXT/identity/$role.md" "$out"
  emit_layer "workflow" "$CONTEXT/workflow.md" "$out"

  if is_in_list "$role" "$COORDINATORS"; then
    emit_layer "workflow-coordination" "$CONTEXT/workflow-coordination.md" "$out"
  fi

  if is_in_list "$role" "$PLAYBOOK_ROLES"; then
    emit_layer "playbook-direct" "$CONTEXT/playbook-direct.md" "$out"
    emit_layer "playbook-lite"   "$CONTEXT/playbook-lite.md" "$out"
    emit_layer "playbook-tdd"    "$CONTEXT/playbook-tdd.md" "$out"
  fi

  emit_layer "role" "$CONTEXT/$role-role.md" "$out"

  bytes="$(wc -c < "$out" | tr -d ' ')"
  printf 'prompts/%-16s %8s bytes\n' "$role.md" "$bytes"
done

# --- settings -------------------------------------------------------------
# Hook commands need an absolute path, so the committed source is a template
# and the rendered file is generated (and gitignored).
printf '\n'
for role in $ROLES; do
  tpl="$SETTINGS/templates/role-$role.json.in"
  dst="$SETTINGS/role-$role.json"
  if [ ! -f "$tpl" ]; then
    fail "missing settings template: $tpl"
    continue
  fi
  tmp="$(mktemp "$SETTINGS/role-$role.XXXXXX")" || { fail "mktemp failed"; continue; }
  sed -e "s|@@INSTALL_DIR@@|$HERE|g" "$tpl" > "$tmp" || { rm -f "$tmp"; fail "render failed for $role"; continue; }

  # A settings file that fails validation is silently ignored by the CLI in
  # some modes, which would drop the permission allowlist and leave every
  # `pipeline tell` blocked behind a dialog. Refuse to ship a broken one.
  if ! jq -e . "$tmp" >/dev/null 2>&1; then
    rm -f "$tmp"
    fail "rendered settings for $role is not valid JSON"
    continue
  fi
  mv "$tmp" "$dst" || { rm -f "$tmp"; fail "could not write $dst"; continue; }
  printf 'settings/%-24s rendered\n' "role-$role.json"
done

if [ "$errors" != "0" ]; then
  printf '\nbuild-prompts: %s error(s)\n' "$errors" >&2
  exit 1
fi
printf '\nBuilt %s role prompts.\n' "$(printf '%s\n' $ROLES | grep -c .)"
