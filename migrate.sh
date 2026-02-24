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

VERSION="1.0.0"

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

# ============================================================
#  Auto-detect the session directory
# ============================================================
# Claude stores sessions under two levels of UUID directories
# tied to the user's account. These are the same across all
# Macs logged into the same Claude account.
#
# Structure:
#   ~/Library/Application Support/Claude/
#     local-agent-mode-sessions/
#       <account-uuid>/
#         <sub-uuid>/
#           local_<session-uuid>.json    (metadata)
#           local_<session-uuid>/        (conversation data)
#             audit.jsonl                (full conversation log)
#             outputs/                   (files created by Cowork)
#             uploads/                   (files uploaded by user)
#             .claude/                   (internal state)
# ============================================================

find_session_dir() {
    local base="$1"

    if [ ! -d "$base" ]; then
        return 1
    fi

    # Look for the nested UUID directories containing local_*.json files
    local session_dir
    session_dir=$(find "$base" -name "local_*.json" -maxdepth 3 -print -quit 2>/dev/null)

    if [ -z "$session_dir" ]; then
        return 1
    fi

    # Return the parent directory of the first json file found
    dirname "$session_dir"
}

# ============================================================
#  Detect username from paths inside session JSON files
# ============================================================
detect_username_in_sessions() {
    local dir="$1"
    # Look at a few JSON files for /Users/<username>/ patterns
    local username
    username=$(grep -ohm1 '/Users/[^/]*/' "$dir"/local_*.json 2>/dev/null | head -1 | sed 's|/Users/||;s|/||')
    echo "$username"
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
    echo "  --force    Overwrite existing sessions during install"
    echo "  --dry-run  Show what would be done without making changes"
    echo "  --help     Show this help message"
    echo ""
    echo "Environment variables:"
    echo "  COWORK_STAGING_DIR  Override staging directory"
    echo "                      (default: ~/cowork-migration)"
    echo ""
    echo "Examples:"
    echo "  # On source Mac (the one you're migrating FROM):"
    echo "  ./migrate.sh export"
    echo ""
    echo "  # Transfer ~/cowork-migration folder to target Mac, then:"
    echo "  ./migrate.sh install"
    echo ""
    echo "  # Force-overwrite a session that transferred with empty data:"
    echo "  ./migrate.sh install --force"
    echo ""
}

# ============================================================
#  LIST: Show all sessions on this Mac
# ============================================================
do_list() {
    echo ""
    echo -e "${BOLD}Cowork Sessions on this Mac${NC}"
    echo "============================================================"
    echo ""

    local session_dir
    session_dir=$(find_session_dir "$SESSION_BASE")

    if [ $? -ne 0 ] || [ -z "$session_dir" ]; then
        echo -e "${RED}No Cowork sessions found.${NC}"
        echo "Make sure Claude Desktop has been opened in Cowork mode."
        exit 1
    fi

    local count=0
    local archived=0

    # Print header
    printf "  %-4s  %-45s  %-12s  %s\n" "#" "TITLE" "DATE" "STATUS"
    printf "  %-4s  %-45s  %-12s  %s\n" "---" "---------------------------------------------" "------------" "--------"

    for json_file in "$session_dir"/local_*.json; do
        [ -f "$json_file" ] || continue
        count=$((count + 1))

        local title is_archived created_at date_str status
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
    echo "  Total: $count sessions ($((count - archived)) active, $archived archived)"
    echo "  Location: $session_dir"
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

    # Find session directory
    local session_dir
    session_dir=$(find_session_dir "$SESSION_BASE")

    if [ $? -ne 0 ] || [ -z "$session_dir" ]; then
        echo -e "${RED}ERROR: No Cowork sessions found.${NC}"
        echo ""
        echo "  Expected location: $SESSION_BASE"
        echo "  Make sure Claude Desktop has been opened in Cowork mode"
        echo "  at least once on this Mac."
        exit 1
    fi

    local source_username
    source_username=$(detect_username_in_sessions "$session_dir")
    local current_username
    current_username=$(whoami)

    echo "  Session directory: $session_dir"
    echo "  Current username:  $current_username"
    if [ -n "$source_username" ]; then
        echo "  Paths reference:   /Users/$source_username/"
    fi
    echo ""

    if [ "$dry_run" = "true" ]; then
        echo -e "  ${YELLOW}DRY RUN - no files will be copied${NC}"
        echo ""
    fi

    # Count sessions
    local total_count=0
    for f in "$session_dir"/local_*.json; do
        [ -f "$f" ] && total_count=$((total_count + 1))
    done

    echo "  Found $total_count sessions to export"
    echo ""

    if [ "$dry_run" = "true" ]; then
        echo "  Would export to: $STAGING_DIR"
        echo ""
        return
    fi

    # Create staging directory
    mkdir -p "$STAGING_DIR/sessions"

    # Save metadata about the export
    cat > "$STAGING_DIR/migration_info.json" << METAEOF
{
    "exported_from": "$(hostname)",
    "exported_by": "$current_username",
    "exported_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "source_username": "${source_username:-$current_username}",
    "session_count": $total_count,
    "tool_version": "$VERSION"
}
METAEOF

    # Copy this script into staging for convenience
    cp "$0" "$STAGING_DIR/migrate.sh" 2>/dev/null || true
    chmod +x "$STAGING_DIR/migrate.sh" 2>/dev/null || true

    local copied=0
    for json_file in "$session_dir"/local_*.json; do
        [ -f "$json_file" ] || continue
        local filename session_id title
        filename=$(basename "$json_file")
        session_id="${filename%.json}"

        title=$(python3 -c "import json; print(json.load(open('$json_file')).get('title', 'Untitled'))" 2>/dev/null || echo "Untitled")
        echo -e "  ${GREEN}EXPORT${NC}  $title"

        # Copy JSON metadata
        cp "$json_file" "$STAGING_DIR/sessions/$filename"

        # Copy session directory (conversation logs, outputs, uploads)
        local source_session_dir="$session_dir/$session_id"
        if [ -d "$source_session_dir" ]; then
            cp -R "$source_session_dir" "$STAGING_DIR/sessions/$session_id"
            local file_count
            file_count=$(find "$STAGING_DIR/sessions/$session_id" -type f 2>/dev/null | wc -l | tr -d ' ')
            echo "          -> $file_count files"
        fi

        copied=$((copied + 1))
    done

    local total_size
    total_size=$(du -sh "$STAGING_DIR" 2>/dev/null | cut -f1)

    echo ""
    echo "============================================================"
    echo -e "  ${GREEN}EXPORT COMPLETE${NC}"
    echo "============================================================"
    echo ""
    echo "  Exported: $copied sessions"
    echo "  Location: $STAGING_DIR"
    echo "  Size:     $total_size"
    echo ""
    echo "  NEXT: Transfer the folder to your target Mac and run:"
    echo ""
    echo "    cd ~/cowork-migration"
    echo "    ./migrate.sh install"
    echo ""
    echo "  Transfer options:"
    echo "    - AirDrop the ~/cowork-migration folder"
    echo "    - scp -r ~/cowork-migration user@target-mac.local:~/"
    echo "    - Copy via USB/Thunderbolt drive"
    echo "    - Copy via shared network folder"
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

    # Check staging directory exists
    if [ ! -d "$STAGING_DIR/sessions" ]; then
        echo -e "${RED}ERROR: No exported sessions found at:${NC}"
        echo "  $STAGING_DIR/sessions"
        echo ""
        echo "  Make sure you've copied the cowork-migration folder"
        echo "  from your source Mac to ~/cowork-migration on this Mac."
        echo ""
        echo "  Or set COWORK_STAGING_DIR to your custom location:"
        echo "    COWORK_STAGING_DIR=/path/to/folder ./migrate.sh install"
        exit 1
    fi

    # Find target session directory
    local target_dir
    target_dir=$(find_session_dir "$SESSION_BASE")

    if [ $? -ne 0 ] || [ -z "$target_dir" ]; then
        echo -e "${RED}ERROR: No Cowork session directory found on this Mac.${NC}"
        echo ""
        echo "  Make sure Claude Desktop has been opened in Cowork mode"
        echo "  at least once on this Mac before running install."
        exit 1
    fi

    # Read migration info if available
    local source_username=""
    if [ -f "$STAGING_DIR/migration_info.json" ]; then
        source_username=$(python3 -c "import json; print(json.load(open('$STAGING_DIR/migration_info.json')).get('source_username', ''))" 2>/dev/null || echo "")
        local exported_from exported_at
        exported_from=$(python3 -c "import json; print(json.load(open('$STAGING_DIR/migration_info.json')).get('exported_from', 'unknown'))" 2>/dev/null || echo "unknown")
        exported_at=$(python3 -c "import json; print(json.load(open('$STAGING_DIR/migration_info.json')).get('exported_at', 'unknown'))" 2>/dev/null || echo "unknown")
        echo "  Exported from: $exported_from"
        echo "  Exported at:   $exported_at"
        echo ""
    fi

    local target_username
    target_username=$(whoami)

    # Determine if path rewriting is needed
    local needs_path_rewrite=false
    if [ -n "$source_username" ] && [ "$source_username" != "$target_username" ]; then
        needs_path_rewrite=true
        echo "  Username change detected: $source_username -> $target_username"
        echo "  Paths will be rewritten automatically."
        echo ""
    fi

    local staged_count=0
    for f in "$STAGING_DIR/sessions"/local_*.json; do
        [ -f "$f" ] && staged_count=$((staged_count + 1))
    done

    local existing_count=0
    for f in "$target_dir"/local_*.json; do
        [ -f "$f" ] && existing_count=$((existing_count + 1))
    done

    echo "  Staged sessions:   $staged_count"
    echo "  Existing sessions: $existing_count"
    if [ "$force" = "true" ]; then
        echo -e "  Mode:              ${YELLOW}FORCE (will overwrite existing)${NC}"
    else
        echo "  Mode:              Safe (skip existing)"
    fi
    if [ "$dry_run" = "true" ]; then
        echo -e "  ${YELLOW}DRY RUN - no files will be modified${NC}"
    fi
    echo ""

    local copied=0
    local skipped=0
    local overwritten=0
    local errors=0

    for json_file in "$STAGING_DIR/sessions"/local_*.json; do
        [ -f "$json_file" ] || continue

        local filename session_id title target_json
        filename=$(basename "$json_file")
        session_id="${filename%.json}"
        target_json="$target_dir/$filename"

        title=$(python3 -c "import json; print(json.load(open('$json_file')).get('title', 'Untitled'))" 2>/dev/null || echo "Untitled")

        # Check if session already exists
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

        # Copy JSON metadata
        cp -f "$json_file" "$target_json"
        if [ $? -ne 0 ]; then
            echo -e "               ${RED}ERROR copying metadata${NC}"
            errors=$((errors + 1))
            continue
        fi

        # Rewrite paths if usernames differ
        if [ "$needs_path_rewrite" = "true" ]; then
            if grep -q "/Users/${source_username}/" "$target_json" 2>/dev/null; then
                sed -i '' "s|/Users/${source_username}/|/Users/${target_username}/|g" "$target_json"
            fi
        fi

        # Copy session directory
        local staged_session_dir="$STAGING_DIR/sessions/$session_id"
        local target_session_dir="$target_dir/$session_id"

        if [ -d "$staged_session_dir" ]; then
            # Remove existing directory if force mode
            if [ "$force" = "true" ] && [ -d "$target_session_dir" ]; then
                rm -rf "$target_session_dir"
            fi

            cp -R "$staged_session_dir" "$target_session_dir"
            if [ $? -ne 0 ]; then
                echo -e "               ${RED}ERROR copying session data${NC}"
                errors=$((errors + 1))
                continue
            fi

            local file_count
            file_count=$(find "$target_session_dir" -type f 2>/dev/null | wc -l | tr -d ' ')
            echo "               -> $file_count files"

            # Rewrite paths inside session files
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

    local final_count=0
    for f in "$target_dir"/local_*.json; do
        [ -f "$f" ] && final_count=$((final_count + 1))
    done

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
#  BACKUP: Create a local backup
# ============================================================
do_backup() {
    echo ""
    echo -e "${BOLD}BACKUP COWORK SESSIONS${NC}"
    echo "============================================================"
    echo ""

    local session_dir
    session_dir=$(find_session_dir "$SESSION_BASE")

    if [ $? -ne 0 ] || [ -z "$session_dir" ]; then
        echo -e "${RED}ERROR: No Cowork sessions found.${NC}"
        exit 1
    fi

    local backup_name="cowork-backup-$(date +%Y%m%d-%H%M%S)"
    local backup_dir="$HOME/$backup_name"

    echo "  Creating backup at: $backup_dir"
    echo ""

    mkdir -p "$backup_dir"
    cp -R "$session_dir"/ "$backup_dir/"

    local count=0
    for f in "$backup_dir"/local_*.json; do
        [ -f "$f" ] && count=$((count + 1))
    done

    local size
    size=$(du -sh "$backup_dir" 2>/dev/null | cut -f1)

    echo ""
    echo -e "  ${GREEN}BACKUP COMPLETE${NC}"
    echo "  Sessions: $count"
    echo "  Size:     $size"
    echo "  Location: $backup_dir"
    echo ""
}

# ============================================================
#  VERIFY: Check migration integrity
# ============================================================
do_verify() {
    echo ""
    echo -e "${BOLD}VERIFY MIGRATION${NC}"
    echo "============================================================"
    echo ""

    # Find session directory on this Mac
    local session_dir
    session_dir=$(find_session_dir "$SESSION_BASE")

    if [ $? -ne 0 ] || [ -z "$session_dir" ]; then
        echo -e "${RED}ERROR: No Cowork sessions found on this Mac.${NC}"
        exit 1
    fi

    # Check if staging directory exists for comparison
    local has_staging=false
    if [ -d "$STAGING_DIR/sessions" ]; then
        has_staging=true
    fi

    local total=0
    local healthy=0
    local warnings=0
    local errors=0
    local issues=""

    for json_file in "$session_dir"/local_*.json; do
        [ -f "$json_file" ] || continue
        total=$((total + 1))

        local filename session_id title session_ok
        filename=$(basename "$json_file")
        session_id="${filename%.json}"
        session_ok=true

        title=$(python3 -c "import json; print(json.load(open('$json_file')).get('title', 'Untitled')[:50])" 2>/dev/null || echo "Untitled")

        local checks=""
        local check_failed=false

        # Check 1: JSON is valid
        if ! python3 -c "import json; json.load(open('$json_file'))" 2>/dev/null; then
            checks="${checks}  ${RED}FAIL${NC} Invalid JSON metadata\n"
            check_failed=true
            errors=$((errors + 1))
            session_ok=false
        fi

        # Check 2: Session directory exists
        local sess_dir="$session_dir/$session_id"
        if [ ! -d "$sess_dir" ]; then
            checks="${checks}  ${YELLOW}WARN${NC} No session directory (metadata only)\n"
            warnings=$((warnings + 1))
            session_ok=false
        else
            # Check 3: audit.jsonl exists and is non-empty
            if [ ! -f "$sess_dir/audit.jsonl" ]; then
                checks="${checks}  ${YELLOW}WARN${NC} Missing audit.jsonl (no conversation log)\n"
                warnings=$((warnings + 1))
                session_ok=false
            elif [ ! -s "$sess_dir/audit.jsonl" ]; then
                checks="${checks}  ${YELLOW}WARN${NC} Empty audit.jsonl (conversation log has no data)\n"
                warnings=$((warnings + 1))
                session_ok=false
            fi

            # Check 4: No stale source-Mac paths remaining
            local current_username
            current_username=$(whoami)
            local stale_paths
            stale_paths=$(grep -r "/Users/" "$sess_dir" --include="*.json" --include="*.jsonl" 2>/dev/null | grep -v "/Users/${current_username}/" | head -1 || true)
            if [ -n "$stale_paths" ]; then
                local stale_user
                stale_user=$(echo "$stale_paths" | grep -o '/Users/[^/]*/' | head -1 | sed 's|/Users/||;s|/||')
                checks="${checks}  ${YELLOW}WARN${NC} Contains paths for /Users/${stale_user}/ (not rewritten)\n"
                warnings=$((warnings + 1))
                session_ok=false
            fi

            # Check 5: Compare with staging if available
            if [ "$has_staging" = "true" ] && [ -f "$STAGING_DIR/sessions/$filename" ]; then
                local staged_dir="$STAGING_DIR/sessions/$session_id"
                if [ -d "$staged_dir" ]; then
                    local staged_files installed_files
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

    echo ""
    echo "============================================================"
    echo -e "  ${BOLD}VERIFICATION RESULTS${NC}"
    echo "============================================================"
    echo ""
    echo "  Total sessions: $total"
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

# Parse flags
FORCE=false
DRY_RUN=false
COMMAND="${1:-}"

shift 2>/dev/null || true

for arg in "$@"; do
    case "$arg" in
        --force) FORCE=true ;;
        --dry-run) DRY_RUN=true ;;
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
