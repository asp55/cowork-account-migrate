#!/bin/bash
# ============================================================
#  Claude Cowork Session Migration Tool
# ============================================================
#  Migrate Claude Desktop Cowork sessions between Macs.
#
#  Two-step process:
#    1. Export on source Mac:  ./migrate.sh export
#    2. Install on target Mac: ./migrate.sh install
#
#  See README.md for full documentation.
# ============================================================

set -euo pipefail

VERSION="1.1.0"

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# --- Configuration ---
STAGING_DIR="${COWORK_STAGING_DIR:-$HOME/cowork-migration}"
SESSION_BASE="$HOME/Library/Application Support/Claude/local-agent-mode-sessions"

# --- Selection flags (populated in main) ---
ACCOUNT_UUID=""
SUB_UUID=""
SELECT_ALL=false

# ============================================================
#  Layout
# ============================================================
# Claude stores sessions under two levels of UUID directories:
#
#   ~/Library/Application Support/Claude/
#     local-agent-mode-sessions/
#       <account-uuid>/                # one per Claude account
#         <sub-uuid>/                  # one or more per account
#           local_<session-uuid>.json  # metadata
#           local_<session-uuid>/      # conversation data
#             audit.jsonl
#             outputs/
#             uploads/
#             .claude/
#
# A "pair" in this script refers to a single
# <account-uuid>/<sub-uuid>/ directory containing session files.
# ============================================================

# ============================================================
#  list_session_pairs <base>
#  Print each <account>/<sub>/ pair (full path) that contains
#  one or more local_*.json files, one per line, sorted.
#  Returns 1 if none found.
# ============================================================
list_session_pairs() {
    local base="$1"
    [ -d "$base" ] || return 1

    local -a pairs=()
    while IFS= read -r -d '' json_path; do
        pairs+=("$(dirname "$json_path")")
    done < <(find "$base" -mindepth 3 -maxdepth 3 -name "local_*.json" -print0 2>/dev/null)

    [ ${#pairs[@]} -gt 0 ] || return 1
    printf '%s\n' "${pairs[@]}" | sort -u
}

# ============================================================
#  pair_session_count <pair-dir>
# ============================================================
pair_session_count() {
    local pair="$1"
    local count=0
    local f
    for f in "$pair"/local_*.json; do
        [ -f "$f" ] && count=$((count + 1))
    done
    echo "$count"
}

# ============================================================
#  detect_source_username <pair-dir> [<pair-dir>...]
#  Look at JSON files for /Users/<name>/ patterns.
# ============================================================
detect_source_username() {
    local pair username=""
    for pair in "$@"; do
        username=$(grep -ohm1 '/Users/[^/]*/' "$pair"/local_*.json 2>/dev/null \
                   | head -1 | sed 's|/Users/||;s|/||')
        [ -n "$username" ] && break
    done
    echo "$username"
}

# ============================================================
#  filter_pairs <pair>...
#  Filter by --account / --sub flags. Prints matching pairs.
# ============================================================
filter_pairs() {
    local pair
    for pair in "$@"; do
        local acc sub
        acc=$(basename "$(dirname "$pair")")
        sub=$(basename "$pair")
        if [ -n "$ACCOUNT_UUID" ] && [ "$acc" != "$ACCOUNT_UUID" ]; then
            continue
        fi
        if [ -n "$SUB_UUID" ] && [ "$sub" != "$SUB_UUID" ]; then
            continue
        fi
        echo "$pair"
    done
}

# ============================================================
#  select_pairs <allow_all> <base>
#  Resolve which pairs the user wants to act on.
#  - Honors --account / --sub / --all flags
#  - If allow_all=true and SELECT_ALL=true, returns all
#  - If a single pair matches, returns it without prompting
#  - Otherwise prints a menu to stderr and reads choice
#  Prints selected pair paths to stdout, one per line.
# ============================================================
select_pairs() {
    local allow_all="$1"
    local base="$2"

    local -a all_pairs=()
    while IFS= read -r p; do
        all_pairs+=("$p")
    done < <(list_session_pairs "$base" 2>/dev/null || true)

    if [ ${#all_pairs[@]} -eq 0 ]; then
        return 1
    fi

    local -a pairs=()
    while IFS= read -r p; do
        pairs+=("$p")
    done < <(filter_pairs "${all_pairs[@]}")

    if [ ${#pairs[@]} -eq 0 ]; then
        echo -e "${RED}No (account/sub) pair matched --account/--sub filter.${NC}" >&2
        echo "  Available pairs:" >&2
        local p acc sub
        for p in "${all_pairs[@]}"; do
            acc=$(basename "$(dirname "$p")")
            sub=$(basename "$p")
            echo "    account=$acc sub=$sub" >&2
        done
        return 1
    fi

    if [ "$SELECT_ALL" = "true" ] && [ "$allow_all" = "true" ]; then
        printf '%s\n' "${pairs[@]}"
        return 0
    fi

    if [ ${#pairs[@]} -eq 1 ]; then
        printf '%s\n' "${pairs[@]}"
        return 0
    fi

    {
        echo ""
        echo -e "${BOLD}Multiple (account-uuid / sub-uuid) pairs found${NC}"
        echo "============================================================"
        echo ""
        local idx=1 p acc sub count
        for p in "${pairs[@]}"; do
            acc=$(basename "$(dirname "$p")")
            sub=$(basename "$p")
            count=$(pair_session_count "$p")
            printf "  %d) account: %s\n" "$idx" "$acc"
            printf "     sub:     %s\n" "$sub"
            printf "     sessions: %d\n\n" "$count"
            idx=$((idx + 1))
        done
        if [ "$allow_all" = "true" ]; then
            echo "  A) All pairs"
            echo ""
            echo -n "  Select [1-${#pairs[@]} or A]: "
        else
            echo -n "  Select [1-${#pairs[@]}]: "
        fi
    } >&2

    local choice
    if ! read -r choice </dev/tty; then
        echo -e "${RED}Could not read selection (no tty).${NC}" >&2
        echo "  Use --account=<uuid> --sub=<uuid> or --all for non-interactive runs." >&2
        return 1
    fi

    if [ "$allow_all" = "true" ] && [[ "$choice" =~ ^[Aa]$ ]]; then
        printf '%s\n' "${pairs[@]}"
        return 0
    fi

    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#pairs[@]}" ]; then
        echo -e "${RED}Invalid selection: $choice${NC}" >&2
        return 1
    fi

    echo "${pairs[$((choice - 1))]}"
}

# ============================================================
#  Show usage
# ============================================================
show_usage() {
    echo ""
    echo -e "${BOLD}Claude Cowork Session Migration Tool v${VERSION}${NC}"
    echo ""
    echo "Usage: $0 <command> [options]"
    echo ""
    echo "Commands:"
    echo "  export     Export sessions from this Mac (run on source Mac)"
    echo "  install    Install exported sessions (run on target Mac)"
    echo "  verify     Verify migration integrity (run on target Mac after install)"
    echo "  list       List all Cowork sessions on this Mac"
    echo "  backup     Create a backup of all sessions on this Mac"
    echo ""
    echo "Options:"
    echo "  --force                Overwrite existing sessions during install"
    echo "  --dry-run              Show what would be done without making changes"
    echo "  --account=<uuid>       Pre-select an account-uuid (skip prompt)"
    echo "  --sub=<uuid>           Pre-select a sub-uuid (skip prompt)"
    echo "  --all                  Select all (account/sub) pairs (export only)"
    echo "  --help                 Show this help message"
    echo ""
    echo "Environment variables:"
    echo "  COWORK_STAGING_DIR     Override staging directory"
    echo "                         (default: ~/cowork-migration)"
    echo ""
    echo "Examples:"
    echo "  # Interactive: prompts if multiple (account/sub) pairs exist"
    echo "  ./migrate.sh export"
    echo ""
    echo "  # Non-interactive: pick a specific pair"
    echo "  ./migrate.sh export --account=AAA-... --sub=BBB-..."
    echo ""
    echo "  # Export every pair on this Mac"
    echo "  ./migrate.sh export --all"
    echo ""
    echo "  # Install everything in staging onto the target Mac"
    echo "  ./migrate.sh install"
    echo ""
}

# ============================================================
#  LIST: Show all sessions on this Mac
# ============================================================
do_list() {
    echo ""
    echo -e "${BOLD}Cowork Sessions on this Mac${NC}"
    echo "============================================================"

    local -a all_pairs=()
    while IFS= read -r p; do
        all_pairs+=("$p")
    done < <(list_session_pairs "$SESSION_BASE" 2>/dev/null || true)

    if [ ${#all_pairs[@]} -eq 0 ]; then
        echo ""
        echo -e "${RED}No Cowork sessions found.${NC}"
        echo "  Expected location: $SESSION_BASE"
        echo "  Make sure Claude Desktop has been opened in Cowork mode."
        exit 1
    fi

    local -a pairs=()
    while IFS= read -r p; do
        pairs+=("$p")
    done < <(filter_pairs "${all_pairs[@]}")

    if [ ${#pairs[@]} -eq 0 ]; then
        echo ""
        echo -e "${RED}No pairs matched the --account/--sub filter.${NC}"
        exit 1
    fi

    local total=0 archived_total=0
    local pair acc sub count archived
    for pair in "${pairs[@]}"; do
        acc=$(basename "$(dirname "$pair")")
        sub=$(basename "$pair")
        echo ""
        echo -e "  ${CYAN}account:${NC} $acc"
        echo -e "  ${CYAN}sub:${NC}     $sub"
        echo ""
        printf "  %-4s  %-45s  %-12s  %s\n" "#" "TITLE" "DATE" "STATUS"
        printf "  %-4s  %-45s  %-12s  %s\n" "---" "---------------------------------------------" "------------" "--------"

        count=0
        archived=0
        local json_file title is_archived created_at status
        for json_file in "$pair"/local_*.json; do
            [ -f "$json_file" ] || continue
            count=$((count + 1))

            title=$(python3 -c "import json; print(json.load(open('$json_file')).get('title', 'Untitled')[:45])" 2>/dev/null || echo "Untitled")
            is_archived=$(python3 -c "import json; print(json.load(open('$json_file')).get('isArchived', False))" 2>/dev/null || echo "False")
            created_at=$(python3 -c "
import json, datetime
ts = json.load(open('$json_file')).get('createdAt', 0)
print(datetime.datetime.fromtimestamp(ts/1000).strftime('%Y-%m-%d'))
" 2>/dev/null || echo "unknown")

            if [ "$is_archived" = "True" ]; then
                status="archived"
                archived=$((archived + 1))
            else
                status="active"
            fi

            printf "  %-4s  %-45s  %-12s  %s\n" "$count" "$title" "$created_at" "$status"
        done

        echo ""
        echo "  Subtotal: $count sessions ($((count - archived)) active, $archived archived)"

        total=$((total + count))
        archived_total=$((archived_total + archived))
    done

    echo ""
    echo "============================================================"
    echo "  Total: $total sessions across ${#pairs[@]} (account/sub) pair(s)"
    echo "  Location: $SESSION_BASE"
    echo ""
}

# ============================================================
#  EXPORT: Package sessions for migration
# ============================================================
do_export() {
    local dry_run="${1:-false}"

    echo ""
    echo -e "${BOLD}STEP 1: EXPORT SESSIONS${NC}"
    echo "============================================================"
    echo ""

    if ! list_session_pairs "$SESSION_BASE" >/dev/null 2>&1; then
        echo -e "${RED}ERROR: No Cowork sessions found.${NC}"
        echo ""
        echo "  Expected location: $SESSION_BASE"
        echo "  Make sure Claude Desktop has been opened in Cowork mode"
        echo "  at least once on this Mac."
        exit 1
    fi

    local -a selected=()
    while IFS= read -r p; do
        selected+=("$p")
    done < <(select_pairs true "$SESSION_BASE")

    if [ ${#selected[@]} -eq 0 ]; then
        echo -e "${RED}No pair selected.${NC}" >&2
        exit 1
    fi

    local current_username source_username
    current_username=$(whoami)
    source_username=$(detect_source_username "${selected[@]}")

    echo ""
    echo "  Current username: $current_username"
    if [ -n "$source_username" ]; then
        echo "  Paths reference:  /Users/$source_username/"
    fi
    echo "  Selected pairs:   ${#selected[@]}"

    local total_count=0 pair c
    for pair in "${selected[@]}"; do
        c=$(pair_session_count "$pair")
        total_count=$((total_count + c))
    done
    echo "  Sessions to export: $total_count"
    echo ""

    if [ "$dry_run" = "true" ]; then
        echo -e "  ${YELLOW}DRY RUN - no files will be copied${NC}"
        echo "  Would export to: $STAGING_DIR"
        echo ""
        return
    fi

    mkdir -p "$STAGING_DIR/sessions"

    local pairs_json="" acc sub
    for pair in "${selected[@]}"; do
        acc=$(basename "$(dirname "$pair")")
        sub=$(basename "$pair")
        if [ -n "$pairs_json" ]; then
            pairs_json="${pairs_json},"
        fi
        pairs_json="${pairs_json}{\"account\":\"$acc\",\"sub\":\"$sub\"}"
    done

    cat > "$STAGING_DIR/migration_info.json" << METAEOF
{
    "exported_from": "$(hostname)",
    "exported_by": "$current_username",
    "exported_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "source_username": "${source_username:-$current_username}",
    "session_count": $total_count,
    "pair_count": ${#selected[@]},
    "pairs": [${pairs_json}],
    "tool_version": "$VERSION"
}
METAEOF

    cp "$0" "$STAGING_DIR/migrate.sh" 2>/dev/null || true
    chmod +x "$STAGING_DIR/migrate.sh" 2>/dev/null || true

    local copied=0 json_file filename session_id title source_session_dir file_count stage_pair
    for pair in "${selected[@]}"; do
        acc=$(basename "$(dirname "$pair")")
        sub=$(basename "$pair")
        stage_pair="$STAGING_DIR/sessions/$acc/$sub"
        mkdir -p "$stage_pair"

        echo -e "  ${CYAN}pair${NC}    account=$acc"
        echo -e "          sub=$sub"

        for json_file in "$pair"/local_*.json; do
            [ -f "$json_file" ] || continue
            filename=$(basename "$json_file")
            session_id="${filename%.json}"

            title=$(python3 -c "import json; print(json.load(open('$json_file')).get('title', 'Untitled'))" 2>/dev/null || echo "Untitled")
            echo -e "  ${GREEN}EXPORT${NC}  $title"

            cp "$json_file" "$stage_pair/$filename"

            source_session_dir="$pair/$session_id"
            if [ -d "$source_session_dir" ]; then
                cp -R "$source_session_dir" "$stage_pair/$session_id"
                file_count=$(find "$stage_pair/$session_id" -type f 2>/dev/null | wc -l | tr -d ' ')
                echo "          -> $file_count files"
            fi

            copied=$((copied + 1))
        done
    done

    local total_size
    total_size=$(du -sh "$STAGING_DIR" 2>/dev/null | cut -f1)

    echo ""
    echo "============================================================"
    echo -e "  ${GREEN}EXPORT COMPLETE${NC}"
    echo "============================================================"
    echo ""
    echo "  Exported: $copied sessions across ${#selected[@]} pair(s)"
    echo "  Location: $STAGING_DIR"
    echo "  Size:     $total_size"
    echo ""
    echo "  NEXT: Transfer the folder to your target Mac and run:"
    echo ""
    echo "    cd ~/cowork-migration"
    echo "    ./migrate.sh install"
    echo ""
}

# ============================================================
#  INSTALL: Import sessions onto this Mac
# ============================================================
do_install() {
    local force="${1:-false}"
    local dry_run="${2:-false}"

    echo ""
    echo -e "${BOLD}STEP 2: INSTALL SESSIONS${NC}"
    echo "============================================================"
    echo ""

    if [ ! -d "$STAGING_DIR/sessions" ]; then
        echo -e "${RED}ERROR: No exported sessions found at:${NC}"
        echo "  $STAGING_DIR/sessions"
        echo ""
        echo "  Make sure you've copied the cowork-migration folder"
        echo "  from your source Mac to ~/cowork-migration on this Mac."
        exit 1
    fi

    local -a staging_all=()
    while IFS= read -r p; do
        staging_all+=("$p")
    done < <(list_session_pairs "$STAGING_DIR/sessions" 2>/dev/null || true)

    if [ ${#staging_all[@]} -eq 0 ]; then
        echo -e "${RED}ERROR: No (account/sub) pairs found in staging.${NC}"
        echo "  Expected layout: $STAGING_DIR/sessions/<account-uuid>/<sub-uuid>/"
        echo "  The staging folder may have been exported by an older version of this tool."
        exit 1
    fi

    local -a staging_pairs=()
    while IFS= read -r p; do
        staging_pairs+=("$p")
    done < <(filter_pairs "${staging_all[@]}")

    if [ ${#staging_pairs[@]} -eq 0 ]; then
        echo -e "${RED}No staged pair matched --account/--sub filter.${NC}"
        exit 1
    fi

    local source_username="" exported_from="" exported_at=""
    if [ -f "$STAGING_DIR/migration_info.json" ]; then
        source_username=$(python3 -c "import json; print(json.load(open('$STAGING_DIR/migration_info.json')).get('source_username', ''))" 2>/dev/null || echo "")
        exported_from=$(python3 -c "import json; print(json.load(open('$STAGING_DIR/migration_info.json')).get('exported_from', 'unknown'))" 2>/dev/null || echo "unknown")
        exported_at=$(python3 -c "import json; print(json.load(open('$STAGING_DIR/migration_info.json')).get('exported_at', 'unknown'))" 2>/dev/null || echo "unknown")
        echo "  Exported from: $exported_from"
        echo "  Exported at:   $exported_at"
        echo ""
    fi

    local target_username
    target_username=$(whoami)

    local needs_path_rewrite=false
    if [ -n "$source_username" ] && [ "$source_username" != "$target_username" ]; then
        needs_path_rewrite=true
        echo "  Username change detected: $source_username -> $target_username"
        echo "  Paths will be rewritten automatically."
        echo ""
    fi

    echo "  Staging pairs: ${#staging_pairs[@]}"
    if [ "$force" = "true" ]; then
        echo -e "  Mode:          ${YELLOW}FORCE (will overwrite existing)${NC}"
    else
        echo "  Mode:          Safe (skip existing)"
    fi
    if [ "$dry_run" = "true" ]; then
        echo -e "  ${YELLOW}DRY RUN - no files will be modified${NC}"
    fi
    echo ""

    local copied=0 skipped=0 overwritten=0 errors=0
    local stage_pair acc sub target_pair json_file filename session_id title target_json
    local staged_session_dir target_session_dir file_count inner_file

    for stage_pair in "${staging_pairs[@]}"; do
        acc=$(basename "$(dirname "$stage_pair")")
        sub=$(basename "$stage_pair")
        target_pair="$SESSION_BASE/$acc/$sub"

        echo -e "  ${CYAN}pair${NC}    account=$acc"
        echo -e "          sub=$sub"

        if [ ! -d "$target_pair" ]; then
            echo -e "          ${YELLOW}target dir does not exist; creating${NC}"
            if [ "$dry_run" != "true" ]; then
                mkdir -p "$target_pair"
            fi
        fi

        for json_file in "$stage_pair"/local_*.json; do
            [ -f "$json_file" ] || continue

            filename=$(basename "$json_file")
            session_id="${filename%.json}"
            target_json="$target_pair/$filename"

            title=$(python3 -c "import json; print(json.load(open('$json_file')).get('title', 'Untitled'))" 2>/dev/null || echo "Untitled")

            if [ -f "$target_json" ]; then
                if [ "$force" = "true" ]; then
                    echo -e "  ${YELLOW}OVERWRITE${NC}  $title"
                    overwritten=$((overwritten + 1))
                else
                    echo -e "  ${YELLOW}SKIP${NC}       $title (already exists)"
                    skipped=$((skipped + 1))
                    continue
                fi
            else
                echo -e "  ${GREEN}INSTALL${NC}    $title"
            fi

            if [ "$dry_run" = "true" ]; then
                copied=$((copied + 1))
                continue
            fi

            if ! cp -f "$json_file" "$target_json"; then
                echo -e "               ${RED}ERROR copying metadata${NC}"
                errors=$((errors + 1))
                continue
            fi

            if [ "$needs_path_rewrite" = "true" ]; then
                if grep -q "/Users/${source_username}/" "$target_json" 2>/dev/null; then
                    sed -i '' "s|/Users/${source_username}/|/Users/${target_username}/|g" "$target_json"
                fi
            fi

            staged_session_dir="$stage_pair/$session_id"
            target_session_dir="$target_pair/$session_id"

            if [ -d "$staged_session_dir" ]; then
                if [ "$force" = "true" ] && [ -d "$target_session_dir" ]; then
                    rm -rf "$target_session_dir"
                fi

                if ! cp -R "$staged_session_dir" "$target_session_dir"; then
                    echo -e "               ${RED}ERROR copying session data${NC}"
                    errors=$((errors + 1))
                    continue
                fi

                file_count=$(find "$target_session_dir" -type f 2>/dev/null | wc -l | tr -d ' ')
                echo "               -> $file_count files"

                if [ "$needs_path_rewrite" = "true" ]; then
                    find "$target_session_dir" \( -name "*.json" -o -name "*.jsonl" -o -name "*.md" \) -print0 2>/dev/null | while IFS= read -r -d '' inner_file; do
                        if grep -q "/Users/${source_username}/" "$inner_file" 2>/dev/null; then
                            sed -i '' "s|/Users/${source_username}/|/Users/${target_username}/|g" "$inner_file"
                        fi
                    done
                fi
            fi

            copied=$((copied + 1))
        done
    done

    local final_count=0 fp
    while IFS= read -r fp; do
        c=$(pair_session_count "$fp")
        final_count=$((final_count + c))
    done < <(list_session_pairs "$SESSION_BASE" 2>/dev/null || true)

    echo ""
    echo "============================================================"
    echo -e "  ${GREEN}INSTALL COMPLETE${NC}"
    echo "============================================================"
    echo ""
    echo "  Installed:   $copied sessions"
    echo "  Overwritten: $overwritten sessions"
    echo "  Skipped:     $skipped (already existed)"
    echo "  Errors:      $errors"
    echo ""
    echo "  This Mac now has $final_count total sessions."
    echo ""
    echo "  NEXT STEPS:"
    echo "    1. Quit Claude Desktop (Cmd+Q)"
    echo "    2. Reopen Claude Desktop"
    echo "    3. Check that sessions appear in the Cowork sidebar"
    echo "    4. Once verified, delete the staging folder:"
    echo "       rm -rf $STAGING_DIR"
    echo ""
}

# ============================================================
#  BACKUP: Create a local backup of all pairs
# ============================================================
do_backup() {
    echo ""
    echo -e "${BOLD}BACKUP COWORK SESSIONS${NC}"
    echo "============================================================"
    echo ""

    local -a all_pairs=()
    while IFS= read -r p; do
        all_pairs+=("$p")
    done < <(list_session_pairs "$SESSION_BASE" 2>/dev/null || true)

    if [ ${#all_pairs[@]} -eq 0 ]; then
        echo -e "${RED}ERROR: No Cowork sessions found.${NC}"
        exit 1
    fi

    local -a pairs=()
    while IFS= read -r p; do
        pairs+=("$p")
    done < <(filter_pairs "${all_pairs[@]}")

    if [ ${#pairs[@]} -eq 0 ]; then
        echo -e "${RED}No pairs matched the --account/--sub filter.${NC}"
        exit 1
    fi

    local backup_name="cowork-backup-$(date +%Y%m%d-%H%M%S)"
    local backup_dir="$HOME/$backup_name"

    echo "  Creating backup at: $backup_dir"
    echo "  Pairs:              ${#pairs[@]}"
    echo ""

    mkdir -p "$backup_dir"

    local total=0 pair acc sub c
    for pair in "${pairs[@]}"; do
        acc=$(basename "$(dirname "$pair")")
        sub=$(basename "$pair")
        mkdir -p "$backup_dir/$acc/$sub"
        cp -R "$pair"/. "$backup_dir/$acc/$sub/"
        c=$(pair_session_count "$pair")
        total=$((total + c))
        echo "  Backed up: account=$acc sub=$sub ($c sessions)"
    done

    local size
    size=$(du -sh "$backup_dir" 2>/dev/null | cut -f1)

    echo ""
    echo -e "  ${GREEN}BACKUP COMPLETE${NC}"
    echo "  Sessions: $total"
    echo "  Size:     $size"
    echo "  Location: $backup_dir"
    echo ""
}

# ============================================================
#  VERIFY: Check migration integrity across all pairs
# ============================================================
do_verify() {
    echo ""
    echo -e "${BOLD}VERIFY MIGRATION${NC}"
    echo "============================================================"
    echo ""

    local -a all_pairs=()
    while IFS= read -r p; do
        all_pairs+=("$p")
    done < <(list_session_pairs "$SESSION_BASE" 2>/dev/null || true)

    if [ ${#all_pairs[@]} -eq 0 ]; then
        echo -e "${RED}ERROR: No Cowork sessions found on this Mac.${NC}"
        exit 1
    fi

    local -a pairs=()
    while IFS= read -r p; do
        pairs+=("$p")
    done < <(filter_pairs "${all_pairs[@]}")

    if [ ${#pairs[@]} -eq 0 ]; then
        echo -e "${RED}No pairs matched the --account/--sub filter.${NC}"
        exit 1
    fi

    local has_staging=false
    if [ -d "$STAGING_DIR/sessions" ] && list_session_pairs "$STAGING_DIR/sessions" >/dev/null 2>&1; then
        has_staging=true
    fi

    local total=0 healthy=0 warnings=0 errors=0 issues=""
    local current_username
    current_username=$(whoami)

    local pair acc sub json_file filename session_id title session_ok checks
    local sess_dir stale_paths stale_user staged_dir staged_files installed_files

    for pair in "${pairs[@]}"; do
        acc=$(basename "$(dirname "$pair")")
        sub=$(basename "$pair")
        echo ""
        echo -e "  ${CYAN}pair${NC}  account=$acc  sub=$sub"
        echo ""

        for json_file in "$pair"/local_*.json; do
            [ -f "$json_file" ] || continue
            total=$((total + 1))

            filename=$(basename "$json_file")
            session_id="${filename%.json}"
            session_ok=true
            checks=""

            title=$(python3 -c "import json; print(json.load(open('$json_file')).get('title', 'Untitled')[:50])" 2>/dev/null || echo "Untitled")

            if ! python3 -c "import json; json.load(open('$json_file'))" 2>/dev/null; then
                checks="${checks}  ${RED}FAIL${NC} Invalid JSON metadata\n"
                errors=$((errors + 1))
                session_ok=false
            fi

            sess_dir="$pair/$session_id"
            if [ ! -d "$sess_dir" ]; then
                checks="${checks}  ${YELLOW}WARN${NC} No session directory (metadata only)\n"
                warnings=$((warnings + 1))
                session_ok=false
            else
                if [ ! -f "$sess_dir/audit.jsonl" ]; then
                    checks="${checks}  ${YELLOW}WARN${NC} Missing audit.jsonl (no conversation log)\n"
                    warnings=$((warnings + 1))
                    session_ok=false
                elif [ ! -s "$sess_dir/audit.jsonl" ]; then
                    checks="${checks}  ${YELLOW}WARN${NC} Empty audit.jsonl (conversation log has no data)\n"
                    warnings=$((warnings + 1))
                    session_ok=false
                fi

                stale_paths=$(grep -r "/Users/" "$sess_dir" --include="*.json" --include="*.jsonl" 2>/dev/null | grep -v "/Users/${current_username}/" | head -1 || true)
                if [ -n "$stale_paths" ]; then
                    stale_user=$(echo "$stale_paths" | grep -o '/Users/[^/]*/' | head -1 | sed 's|/Users/||;s|/||')
                    checks="${checks}  ${YELLOW}WARN${NC} Contains paths for /Users/${stale_user}/ (not rewritten)\n"
                    warnings=$((warnings + 1))
                    session_ok=false
                fi

                if [ "$has_staging" = "true" ] && [ -f "$STAGING_DIR/sessions/$acc/$sub/$filename" ]; then
                    staged_dir="$STAGING_DIR/sessions/$acc/$sub/$session_id"
                    if [ -d "$staged_dir" ]; then
                        staged_files=$(find "$staged_dir" -type f 2>/dev/null | wc -l | tr -d ' ')
                        installed_files=$(find "$sess_dir" -type f 2>/dev/null | wc -l | tr -d ' ')
                        if [ "$installed_files" -lt "$staged_files" ]; then
                            checks="${checks}  ${YELLOW}WARN${NC} Missing files: $installed_files installed vs $staged_files exported\n"
                            warnings=$((warnings + 1))
                            session_ok=false
                        fi
                    fi
                fi
            fi

            if [ "$session_ok" = "true" ]; then
                healthy=$((healthy + 1))
                echo -e "  ${GREEN}OK${NC}    $title"
            else
                echo -e "  ${YELLOW}ISSUE${NC} $title"
                echo -e "$checks"
                issues="${issues}  - $title\n"
            fi
        done
    done

    echo ""
    echo "============================================================"
    echo -e "  ${BOLD}VERIFICATION RESULTS${NC}"
    echo "============================================================"
    echo ""
    echo "  Total sessions: $total across ${#pairs[@]} (account/sub) pair(s)"
    echo -e "  ${GREEN}Healthy:${NC}  $healthy"
    echo -e "  ${YELLOW}Warnings:${NC} $warnings"
    echo -e "  ${RED}Errors:${NC}   $errors"
    echo ""

    if [ "$warnings" -gt 0 ] || [ "$errors" -gt 0 ]; then
        echo "  Sessions with issues:"
        echo -e "$issues"
        echo ""
        if [ "$has_staging" = "true" ]; then
            echo "  To fix sessions with missing data, re-run:"
            echo "    ./migrate.sh install --force"
        else
            echo "  To fix, re-export from source Mac and install with --force"
        fi
        echo ""
    else
        echo -e "  ${GREEN}All sessions verified successfully.${NC}"
        echo ""
        echo "  You can safely delete the staging folder:"
        echo "    rm -rf $STAGING_DIR"
        echo ""
    fi
}

# ============================================================
#  MAIN
# ============================================================

FORCE=false
DRY_RUN=false
COMMAND="${1:-}"

shift 2>/dev/null || true

for arg in "$@"; do
    case "$arg" in
        --force) FORCE=true ;;
        --dry-run) DRY_RUN=true ;;
        --all) SELECT_ALL=true ;;
        --account=*) ACCOUNT_UUID="${arg#--account=}" ;;
        --sub=*) SUB_UUID="${arg#--sub=}" ;;
        --help) show_usage; exit 0 ;;
    esac
done

case "$COMMAND" in
    export)
        do_export "$DRY_RUN"
        ;;
    install)
        do_install "$FORCE" "$DRY_RUN"
        ;;
    verify)
        do_verify
        ;;
    list)
        do_list
        ;;
    backup)
        do_backup
        ;;
    --help|-h|help)
        show_usage
        ;;
    *)
        show_usage
        exit 1
        ;;
esac
