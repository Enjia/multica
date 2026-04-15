#!/usr/bin/env bash
# Import skills from ~/.codex/skills/ into Multica platform.
#
# Usage: bash scripts/import-codex-skills.sh
#
# Prerequisites:
#   - multica CLI is installed and authenticated (`multica config`)
#   - A workspace is selected
#
# What it does:
#   1. Scans ~/.codex/skills/ for directories containing SKILL.md
#   2. Creates each skill via `multica skill create`
#   3. Uploads supporting files via `multica skill files upsert`
#   4. Skips empty dirs, .system, .venv, binary files, etc.

set -euo pipefail

SKILLS_DIR="${HOME}/.codex/skills"

# Directories to skip entirely (empty or system).
SKIP_DIRS=(".system" "cuda" "sglang-memory")

# Path patterns to skip when scanning supporting files.
SKIP_PATTERNS=(".venv/" ".ssh-control/" "__pycache__/" "node_modules/" ".git/" ".pyc" ".bak.")

log()  { echo "[import] $*"; }
warn() { echo "[import] WARNING: $*" >&2; }

should_skip_file() {
  local relpath="$1"
  for pattern in "${SKIP_PATTERNS[@]}"; do
    if [[ "$relpath" == *"$pattern"* ]]; then
      return 0
    fi
  done
  return 1
}

is_binary() {
  file --mime-encoding "$1" 2>/dev/null | grep -q "binary"
}

imported=0
skipped=0
failed=0

for skill_dir in "${SKILLS_DIR}"/*/; do
  skill_name=$(basename "$skill_dir")

  # Skip excluded directories.
  skip=false
  for sd in "${SKIP_DIRS[@]}"; do
    [[ "$skill_name" == "$sd" ]] && { skip=true; break; }
  done
  if $skip; then
    log "Skipping excluded: $skill_name"
    ((skipped++)) || true
    continue
  fi

  # Must have SKILL.md.
  if [[ ! -f "${skill_dir}/SKILL.md" ]]; then
    warn "No SKILL.md in $skill_name — skipping"
    ((skipped++)) || true
    continue
  fi

  log "━━━ Importing: $skill_name ━━━"

  # Step 1: Create the skill with SKILL.md as content.
  skill_content=$(cat "${skill_dir}/SKILL.md")
  create_output=$(multica skill create \
    --name "$skill_name" \
    --content "$skill_content" \
    --output json 2>&1) || {
    warn "Failed to create skill '$skill_name': $create_output"
    ((failed++)) || true
    continue
  }

  skill_id=$(echo "$create_output" | jq -r '.id // empty' 2>/dev/null || true)
  if [[ -z "$skill_id" ]]; then
    warn "Could not extract skill ID for '$skill_name': $create_output"
    ((failed++)) || true
    continue
  fi

  log "  Created skill: $skill_name (${skill_id:0:8}...)"

  # Step 2: Upload supporting files.
  file_count=0
  while IFS= read -r -d '' filepath; do
    relpath="${filepath#"${skill_dir}"}"
    relpath="${relpath#/}"  # strip leading slash from double-slash paths

    # Skip SKILL.md (already used as content).
    [[ "$relpath" == "SKILL.md" ]] && continue

    # Skip excluded patterns.
    if should_skip_file "$relpath"; then
      log "  Skipping: $relpath (excluded pattern)"
      continue
    fi

    # Skip binary files.
    if is_binary "$filepath"; then
      log "  Skipping: $relpath (binary)"
      continue
    fi

    file_content=$(cat "$filepath")
    upsert_output=$(multica skill files upsert "$skill_id" \
      --path "$relpath" \
      --content "$file_content" \
      --output json 2>&1) || {
      warn "  Failed to upload file '$relpath': $upsert_output"
      continue
    }

    log "  Uploaded: $relpath"
    ((file_count++)) || true
  done < <(find "$skill_dir" -type f -print0)

  log "  Done ($file_count supporting files)"
  ((imported++)) || true
done

echo ""
echo "========================================="
echo "  Import complete!"
echo "  Imported: $imported"
echo "  Skipped:  $skipped"
echo "  Failed:   $failed"
echo "========================================="
