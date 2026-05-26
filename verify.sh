#!/bin/bash
# ============================================================
#  Claude Cowork Session Verification Tool
# ============================================================
#  Run on any Mac to verify all Cowork sessions are healthy.
#
#  Checks:
#    - JSON metadata is valid and parseable
#    - Session directories exist with conversation data
#    - audit.jsonl (conversation log) exists and is non-empty
#    - File paths reference the correct username
#    - Referenced files and folders actually exist on disk
#    - Output files from Cowork are present
#
#  Iterates across every <account-uuid>/<sub-uuid>/ pair under
#  the session base. Use --account / --sub to restrict scope.
#
#  Usage:
#    ./verify.sh                      # Verify every pair on this Mac
#    ./verify.sh --verbose            # Show detailed per-file checks
#    ./verify.sh --fix                # Attempt to fix stale username paths
#    ./verify.sh --account=<uuid>     # Limit to one account-uuid
#    ./verify.sh --sub=<uuid>         # Limit to one sub-uuid
# ============================================================

set -euo pipefail

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# --- Options ---
VERBOSE=false
FIX_PATHS=false
ACCOUNT_UUID=""
SUB_UUID=""

for arg in "$@"; do
    case "$arg" in
        --verbose|-v) VERBOSE=true ;;
        --fix) FIX_PATHS=true ;;
        --account=*) ACCOUNT_UUID="${arg#--account=}" ;;
        --sub=*) SUB_UUID="${arg#--sub=}" ;;
        --help|-h)
            echo "Usage: $0 [--verbose] [--fix] [--account=<uuid>] [--sub=<uuid>]"
            echo ""
            echo "  --verbose          Show detailed per-file checks for each session"
            echo "  --fix              Attempt to rewrite stale username paths"
            echo "  --account=<uuid>   Limit verification to one account-uuid"
            echo "  --sub=<uuid>       Limit verification to one sub-uuid"
            echo ""
            exit 0
            ;;
    esac
done

SESSION_BASE="$HOME/Library/Application Support/Claude/local-agent-mode-sessions"
CURRENT_USER=$(whoami)

echo ""
echo -e "${BOLD}Claude Cowork Session Verification${NC}"
echo "============================================================"
echo ""
echo "  Mac:      $(hostname)"
echo "  User:     $CURRENT_USER"
echo "  Checking: $SESSION_BASE"
echo ""

if [ ! -d "$SESSION_BASE" ]; then
    echo -e "${RED}ERROR: Session base directory not found.${NC}"
    echo "  Claude Desktop may not have been used in Cowork mode on this Mac."
    exit 1
fi

# Enumerate <account-uuid>/<sub-uuid>/ pairs containing local_*.json files
declare -a ALL_PAIRS=()
while IFS= read -r -d '' json_path; do
    ALL_PAIRS+=("$(dirname "$json_path")")
done < <(find "$SESSION_BASE" -mindepth 3 -maxdepth 3 -name "local_*.json" -print0 2>/dev/null)

if [ ${#ALL_PAIRS[@]} -eq 0 ]; then
    echo -e "${RED}ERROR: No session files found.${NC}"
    exit 1
fi

# Dedupe and sort
declare -a UNIQUE_PAIRS=()
while IFS= read -r p; do
    UNIQUE_PAIRS+=("$p")
done < <(printf '%s\n' "${ALL_PAIRS[@]}" | sort -u)

# Apply --account / --sub filters
declare -a PAIRS=()
for p in "${UNIQUE_PAIRS[@]}"; do
    acc=$(basename "$(dirname "$p")")
    sub=$(basename "$p")
    if [ -n "$ACCOUNT_UUID" ] && [ "$acc" != "$ACCOUNT_UUID" ]; then
        continue
    fi
    if [ -n "$SUB_UUID" ] && [ "$sub" != "$SUB_UUID" ]; then
        continue
    fi
    PAIRS+=("$p")
done

if [ ${#PAIRS[@]} -eq 0 ]; then
    echo -e "${RED}ERROR: No pairs matched --account/--sub filter.${NC}"
    echo "  Available pairs:"
    for p in "${UNIQUE_PAIRS[@]}"; do
        echo "    account=$(basename "$(dirname "$p")") sub=$(basename "$p")"
    done
    exit 1
fi

echo "  Pairs:    ${#PAIRS[@]}"
echo ""
echo "============================================================"

# --- Counters (across all pairs) ---
TOTAL=0
HEALTHY=0
WARN_COUNT=0
ERROR_COUNT=0
FIXED=0
declare -a PROBLEM_SESSIONS=()

for SESSION_DIR in "${PAIRS[@]}"; do
    pair_acc=$(basename "$(dirname "$SESSION_DIR")")
    pair_sub=$(basename "$SESSION_DIR")
    echo ""
    echo -e "  ${CYAN}pair${NC}  account=$pair_acc  sub=$pair_sub"
    echo ""

    for json_file in "$SESSION_DIR"/local_*.json; do
        [ -f "$json_file" ] || continue
        TOTAL=$((TOTAL + 1))

        filename=$(basename "$json_file")
        session_id="${filename%.json}"
        session_issues=0
        session_warnings=""

        # --- Extract metadata ---
        title=$(python3 -c "import json; print(json.load(open('$json_file')).get('title', 'Untitled')[:55])" 2>/dev/null || echo "Untitled")
        created_at=$(python3 -c "
import json, datetime
ts = json.load(open('$json_file')).get('createdAt', 0)
print(datetime.datetime.fromtimestamp(ts/1000).strftime('%Y-%m-%d %H:%M'))
" 2>/dev/null || echo "unknown")
        is_archived=$(python3 -c "import json; print(json.load(open('$json_file')).get('isArchived', False))" 2>/dev/null || echo "False")

        status_tag=""
        if [ "$is_archived" = "True" ]; then
            status_tag=" ${DIM}(archived)${NC}"
        fi

        # CHECK 1: Valid JSON
        if ! python3 -c "import json; json.load(open('$json_file'))" 2>/dev/null; then
            session_warnings="${session_warnings}    ${RED}FAIL${NC}  Metadata JSON is invalid/corrupt\n"
            session_issues=$((session_issues + 1))
            ERROR_COUNT=$((ERROR_COUNT + 1))
        elif [ "$VERBOSE" = "true" ]; then
            session_warnings="${session_warnings}    ${GREEN}OK${NC}    Metadata JSON is valid\n"
        fi

        # CHECK 2: Session directory exists
        sess_dir="$SESSION_DIR/$session_id"
        if [ ! -d "$sess_dir" ]; then
            session_warnings="${session_warnings}    ${YELLOW}WARN${NC}  No session directory (metadata only, no chat data)\n"
            session_issues=$((session_issues + 1))
            WARN_COUNT=$((WARN_COUNT + 1))

            if [ "$session_issues" -gt 0 ]; then
                echo -e "  ${YELLOW}ISSUE${NC} $title${status_tag} ($created_at)"
                echo -e "$session_warnings"
                PROBLEM_SESSIONS+=("$title")
            else
                HEALTHY=$((HEALTHY + 1))
                echo -e "  ${GREEN}OK${NC}    $title${status_tag}"
            fi
            continue
        fi

        # CHECK 3: audit.jsonl exists and has content
        audit_file="$sess_dir/audit.jsonl"
        if [ ! -f "$audit_file" ]; then
            session_warnings="${session_warnings}    ${YELLOW}WARN${NC}  Missing audit.jsonl (no conversation log)\n"
            session_issues=$((session_issues + 1))
            WARN_COUNT=$((WARN_COUNT + 1))
        elif [ ! -s "$audit_file" ]; then
            session_warnings="${session_warnings}    ${YELLOW}WARN${NC}  audit.jsonl is empty (0 bytes)\n"
            session_issues=$((session_issues + 1))
            WARN_COUNT=$((WARN_COUNT + 1))
        elif [ "$VERBOSE" = "true" ]; then
            audit_size=$(du -h "$audit_file" 2>/dev/null | cut -f1 | tr -d ' ')
            audit_lines=$(wc -l < "$audit_file" | tr -d ' ')
            session_warnings="${session_warnings}    ${GREEN}OK${NC}    Conversation log: $audit_lines entries ($audit_size)\n"
        fi

        # CHECK 4: Stale username paths
        stale_user=""
        stale_match=$(grep -ohm1 '/Users/[^/"]*/' "$json_file" 2>/dev/null | grep -v "/Users/${CURRENT_USER}/" | head -1 || true)
        if [ -n "$stale_match" ]; then
            stale_user=$(echo "$stale_match" | sed 's|/Users/||;s|/||')
        fi

        if [ -n "$stale_user" ]; then
            stale_count_meta=$(grep -c "/Users/${stale_user}/" "$json_file" 2>/dev/null || echo "0")
            stale_count_audit=0
            if [ -f "$audit_file" ]; then
                stale_count_audit=$(grep -c "/Users/${stale_user}/" "$audit_file" 2>/dev/null || echo "0")
            fi

            session_warnings="${session_warnings}    ${YELLOW}WARN${NC}  Contains /Users/${stale_user}/ paths (metadata: ${stale_count_meta}, audit: ${stale_count_audit})\n"
            session_issues=$((session_issues + 1))
            WARN_COUNT=$((WARN_COUNT + 1))

            if [ "$FIX_PATHS" = "true" ]; then
                sed -i '' "s|/Users/${stale_user}/|/Users/${CURRENT_USER}/|g" "$json_file"
                session_warnings="${session_warnings}    ${GREEN}FIXED${NC} Rewrote paths in metadata: /Users/${stale_user}/ -> /Users/${CURRENT_USER}/\n"

                find "$sess_dir" \( -name "*.json" -o -name "*.jsonl" -o -name "*.md" \) -print0 2>/dev/null | while IFS= read -r -d '' inner_file; do
                    if grep -q "/Users/${stale_user}/" "$inner_file" 2>/dev/null; then
                        sed -i '' "s|/Users/${stale_user}/|/Users/${CURRENT_USER}/|g" "$inner_file"
                    fi
                done
                session_warnings="${session_warnings}    ${GREEN}FIXED${NC} Rewrote paths in session files\n"
                FIXED=$((FIXED + 1))
            fi
        elif [ "$VERBOSE" = "true" ]; then
            session_warnings="${session_warnings}    ${GREEN}OK${NC}    All paths reference /Users/${CURRENT_USER}/\n"
        fi

        # CHECK 5: Referenced folders exist on disk
        referenced_folders=$(python3 -c "
import json
data = json.load(open('$json_file'))
folders = data.get('userSelectedFolders', [])
paths = data.get('userApprovedFileAccessPaths', [])
all_paths = list(set(folders + paths))
for p in all_paths:
    if p:
        print(p)
" 2>/dev/null || true)

        if [ -n "$referenced_folders" ]; then
            missing_folders=0
            total_folders=0
            while IFS= read -r folder_path; do
                total_folders=$((total_folders + 1))
                if [ ! -e "$folder_path" ]; then
                    missing_folders=$((missing_folders + 1))
                    if [ "$VERBOSE" = "true" ]; then
                        session_warnings="${session_warnings}    ${YELLOW}WARN${NC}  Missing: $folder_path\n"
                    fi
                fi
            done <<< "$referenced_folders"

            if [ "$missing_folders" -gt 0 ]; then
                session_warnings="${session_warnings}    ${YELLOW}WARN${NC}  $missing_folders of $total_folders referenced paths not found on disk\n"
                session_issues=$((session_issues + 1))
                WARN_COUNT=$((WARN_COUNT + 1))
            elif [ "$VERBOSE" = "true" ]; then
                session_warnings="${session_warnings}    ${GREEN}OK${NC}    All $total_folders referenced paths exist\n"
            fi
        fi

        # CHECK 6: Output files
        outputs_dir="$sess_dir/outputs"
        if [ -d "$outputs_dir" ]; then
            output_count=$(find "$outputs_dir" -type f 2>/dev/null | wc -l | tr -d ' ')
            if [ "$VERBOSE" = "true" ] && [ "$output_count" -gt 0 ]; then
                session_warnings="${session_warnings}    ${GREEN}OK${NC}    Output files: $output_count\n"
            fi
        fi

        uploads_dir="$sess_dir/uploads"
        if [ -d "$uploads_dir" ]; then
            upload_count=$(find "$uploads_dir" -type f 2>/dev/null | wc -l | tr -d ' ')
            if [ "$VERBOSE" = "true" ] && [ "$upload_count" -gt 0 ]; then
                session_warnings="${session_warnings}    ${GREEN}OK${NC}    Uploaded files: $upload_count\n"
            fi
        fi

        # CHECK 7: Total file count in session
        if [ "$VERBOSE" = "true" ]; then
            total_files=$(find "$sess_dir" -type f 2>/dev/null | wc -l | tr -d ' ')
            total_size=$(du -sh "$sess_dir" 2>/dev/null | cut -f1 | tr -d ' ')
            session_warnings="${session_warnings}    ${DIM}INFO${NC}  Total: $total_files files, $total_size\n"
        fi

        # --- Print session result ---
        if [ "$session_issues" -gt 0 ]; then
            echo -e "  ${YELLOW}ISSUE${NC} $title${status_tag} ($created_at)"
            echo -e "$session_warnings"
            PROBLEM_SESSIONS+=("$title")
        else
            if [ "$VERBOSE" = "true" ]; then
                echo -e "  ${GREEN}OK${NC}    $title${status_tag} ($created_at)"
                echo -e "$session_warnings"
            else
                echo -e "  ${GREEN}OK${NC}    $title${status_tag}"
            fi
            HEALTHY=$((HEALTHY + 1))
        fi
    done
done

# --- Summary ---
echo ""
echo "============================================================"
echo -e "  ${BOLD}VERIFICATION SUMMARY${NC}"
echo "============================================================"
echo ""
echo "  Total sessions: $TOTAL across ${#PAIRS[@]} (account/sub) pair(s)"
echo -e "  ${GREEN}Healthy:${NC}  $HEALTHY"
echo -e "  ${YELLOW}Warnings:${NC} $WARN_COUNT"
echo -e "  ${RED}Errors:${NC}   $ERROR_COUNT"

if [ "$FIXED" -gt 0 ]; then
    echo -e "  ${GREEN}Fixed:${NC}    $FIXED sessions (paths rewritten)"
fi

echo ""

if [ ${#PROBLEM_SESSIONS[@]} -gt 0 ]; then
    echo "  Sessions with issues:"
    for sess in "${PROBLEM_SESSIONS[@]}"; do
        echo "    - $sess"
    done
    echo ""

    if [ "$FIX_PATHS" = "false" ]; then
        echo "  To fix stale username paths, re-run with:"
        echo "    ./verify.sh --fix"
        echo ""
        echo "  For sessions with missing data, re-export from the"
        echo "  source Mac and install with --force:"
        echo "    ./migrate.sh install --force"
        echo ""
    fi
else
    echo -e "  ${GREEN}All sessions verified successfully!${NC}"
    echo ""
fi
