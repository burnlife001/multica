#!/usr/bin/env bash
# -*- coding: utf-8 -*-
# Multica Remote Agent Manager — menu-driven agent deletion on remote server.
# Usage: bash __multica-agent-mgr.sh

set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────
REMOTE_HOST="192.168.1.123"
REMOTE_USER="yg"
DB_HOST="localhost"
DB_NAME="multica"
DB_USER="multica"
DB_PASS="multica"

# ── Helpers ────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

db() {
    # Pipe SQL via stdin to avoid shell quoting issues with -c and embedded quotes.
    printf '%s' "$1" | ssh "${REMOTE_USER}@${REMOTE_HOST}" \
        "PGPASSWORD=${DB_PASS} psql -h ${DB_HOST} -U ${DB_USER} -d ${DB_NAME} -At -F '|'"
}

db_raw() {
    printf '%s' "$1" | ssh "${REMOTE_USER}@${REMOTE_HOST}" \
        "PGPASSWORD=${DB_PASS} psql -h ${DB_HOST} -U ${DB_USER} -d ${DB_NAME}"
}

# ── List agents ────────────────────────────────────────────────────────────
list_agents() {
    echo ""
    printf "${BOLD}${CYAN}%s${NC}\n" "══════════════════════════════════════════════════════════════════"
    printf "${BOLD}${CYAN}  Remote Agents on %s${NC}\n" "${REMOTE_HOST}"
    printf "${BOLD}${CYAN}%s${NC}\n" "══════════════════════════════════════════════════════════════════"
    echo ""

    local sql="SELECT id, name, status, visibility, runtime_mode, to_char(created_at,'YYYY-MM-DD HH24:MI') FROM agent ORDER BY created_at DESC;"
    local data
    data=$(db "$sql")

    if [[ -z "$data" ]]; then
        printf "${YELLOW}  No agents found on remote server.${NC}\n\n"
        return 1
    fi

    local count=0
    local index=1
    # map array: index → id
    declare -gA AGENT_ID_MAP=()
    declare -gA AGENT_NAME_MAP=()

    while IFS='|' read -r id name status visibility runtime_mode created; do
        AGENT_ID_MAP[$index]="$id"
        AGENT_NAME_MAP[$index]="$name"
        count=$index

        local s_color=""
        case "$status" in
            idle)    s_color="${GREEN}" ;;
            working) s_color="${CYAN}" ;;
            error)   s_color="${RED}" ;;
            offline) s_color="${YELLOW}" ;;
            blocked) s_color="${YELLOW}" ;;
            *)       s_color="${NC}" ;;
        esac

        printf "  ${BOLD}[%2d]${NC} %s\n" "$index" "$name"
        printf "        id=%-36s  status=${s_color}%-8s${NC}  mode=%-6s  visibility=%-9s  created=%s\n" \
            "$id" "$status" "$runtime_mode" "$visibility" "$created"
        ((index++))
    done <<< "$data"

    echo ""
    printf "  ${YELLOW}Total: %d agent(s)${NC}\n" "$count"
    echo ""
    return 0
}

# ── Show agent dependencies ────────────────────────────────────────────────
show_dependencies() {
    local agent_id="$1"
    local agent_name="$2"

    printf "\n  ${YELLOW}Dependencies for \"%s\":${NC}\n" "$agent_name"

    local sql="
        SELECT 'agent_skill'       , count(*) FROM agent_skill       WHERE agent_id = '${agent_id}'
        UNION ALL
        SELECT 'agent_task_queue'  , count(*) FROM agent_task_queue  WHERE agent_id = '${agent_id}'
        UNION ALL
        SELECT 'autopilot'         , count(*) FROM autopilot         WHERE assignee_id = '${agent_id}'
        UNION ALL
        SELECT 'chat_session'      , count(*) FROM chat_session      WHERE agent_id = '${agent_id}'
        UNION ALL
        SELECT 'daemon_connection' , count(*) FROM daemon_connection WHERE agent_id = '${agent_id}'
        ORDER BY 1;
    "

    local deps
    deps=$(db "$sql")

    local has_deps=false
    while IFS='|' read -r tbl cnt; do
        if [[ "$cnt" -gt 0 ]]; then
            has_deps=true
            printf "    ${RED}%-20s → %s row(s) will be cascade-deleted${NC}\n" "$tbl" "$cnt"
        fi
    done <<< "$deps"

    if [[ "$has_deps" == false ]]; then
        printf "    ${GREEN}No dependencies — safe to delete.${NC}\n"
    fi
    echo ""
}

# ── Delete agent ───────────────────────────────────────────────────────────
delete_agent() {
    local agent_id="$1"
    local agent_name="$2"

    printf "\n  ${RED}Deleting \"%s\" (id=%s)...${NC}\n" "$agent_name" "$agent_id"

    local sql="DELETE FROM agent WHERE id = '${agent_id}';"
    if ! db "$sql"; then
        printf "  ${RED}Delete failed.${NC}\n"
        return 1
    fi

    printf "  ${GREEN}Agent \"%s\" deleted successfully.${NC}\n" "$agent_name"

    # Verify
    local check
    check=$(db "SELECT count(*) FROM agent WHERE id = '${agent_id}';")
    if [[ "$check" == "0" ]]; then
        printf "  ${GREEN}Verification: agent no longer exists in database.${NC}\n"
    else
        printf "  ${RED}Verification FAILED: agent still exists!${NC}\n"
        return 1
    fi
    return 0
}

# ── Interactive selection ──────────────────────────────────────────────────
select_and_delete() {
    if ! list_agents; then
        return
    fi

    printf "  ${BOLD}Enter agent number to delete, or 0 to go back:${NC} "
    read -r choice

    if [[ "$choice" == "0" || -z "$choice" ]]; then
        return
    fi

    if [[ ! -v AGENT_ID_MAP[$choice] ]]; then
        printf "\n  ${RED}Invalid choice: %s${NC}\n" "$choice"
        return
    fi

    local agent_id="${AGENT_ID_MAP[$choice]}"
    local agent_name="${AGENT_NAME_MAP[$choice]}"

    show_dependencies "$agent_id" "$agent_name"

    delete_agent "$agent_id" "$agent_name"
}

# ── Bulk delete by name pattern ────────────────────────────────────────────
delete_by_name() {
    printf "\n  ${BOLD}Enter full agent name (exact match):${NC} "
    read -r name

    if [[ -z "$name" ]]; then
        return
    fi

    local sql="SELECT id, name FROM agent WHERE name = '${name}';"
    local match
    match=$(db "$sql")

    if [[ -z "$match" ]]; then
        printf "\n  ${YELLOW}No agent found with name \"%s\".${NC}\n" "$name"
        return
    fi

    local count
    count=$(echo "$match" | wc -l)
    local id
    id=$(echo "$match" | cut -d'|' -f1 | head -1)
    local found_name
    found_name=$(echo "$match" | cut -d'|' -f2 | head -1)

    printf "\n  Found: %s (id=%s)\n" "$found_name" "$id"
    if [[ "$count" -gt 1 ]]; then
        printf "  ${YELLOW}Warning: %d agents match this name. Only the first will be deleted.${NC}\n" "$count"
    fi

    show_dependencies "$id" "$found_name"

    delete_agent "$id" "$found_name"
}

# ── Main menu ──────────────────────────────────────────────────────────────
main_menu() {
    while true; do
        clear 2>/dev/null || true
        echo ""
        printf "${BOLD}${CYAN}%s${NC}\n" "╔══════════════════════════════════════════════╗"
        printf "${BOLD}${CYAN}%s${NC}\n" "║   Multica Remote Agent Manager              ║"
        printf "${BOLD}${CYAN}%s${NC}\n" "║   Target: ${REMOTE_USER}@${REMOTE_HOST}                   ║"
        printf "${BOLD}${CYAN}%s${NC}\n" "╚══════════════════════════════════════════════╝"
        echo ""
        printf "  ${BOLD}1)${NC} List & delete agent   (interactive pick)\n"
        printf "  ${BOLD}2)${NC} Delete by name         (exact match)\n"
        echo ""
        printf "  ${BOLD}0)${NC} Exit\n"
        echo ""
        printf "  ${BOLD}Select [0-3]:${NC} "
        read -r choice

        case "$choice" in
            1) select_and_delete
               ;;
            2) delete_by_name
               ;;
            0) echo ""; echo "  Bye."; exit 0
               ;;
            *) printf "\n  ${RED}Invalid choice: %s${NC}\n" "$choice"
               ;;
        esac

        if [[ "$choice" != "0" ]]; then
            echo ""
            printf "  ${YELLOW}Press Enter to continue...${NC}"
            read -r
        fi
    done
}

main_menu
