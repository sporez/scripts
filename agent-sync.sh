#!/usr/bin/env bash

set -euo pipefail

SCRIPT_NAME=$(basename "$0")

COMMAND=""
HOST=""
REMOTE_HOME_OVERRIDE=""
REMOTE_PI_DIR_OVERRIDE=""
AGENT_ARG="all"
PART_ARG="default"
DRY_RUN=0
VERBOSE=0
BACKUP=0
DELETE_MODE=0

LOCAL_PI_DIR="${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}"
REMOTE_HOME=""
REMOTE_PI_DIR=""
TIMESTAMP=$(date +%Y%m%d-%H%M%S)

usage() {
    cat <<EOF
Usage:
  $SCRIPT_NAME list
  $SCRIPT_NAME paths [options]
  $SCRIPT_NAME push --host user@host [options]
  $SCRIPT_NAME pull --host user@host [options]

Sync OpenCode and Pi user-level config between systems with rsync over SSH.

Commands:
  list              Show supported agents and parts
  paths             Show resolved local paths, and remote paths if --host is set
  push              Sync from this machine to --host
  pull              Sync from --host to this machine

Options:
  --host HOST             Remote SSH target, for example user@newbox
  --agent LIST            opencode, pi, or all (default: all)
  --part LIST             default, all, or comma-separated part names
  --remote-home PATH      Override remote home directory
  --remote-pi-dir PATH    Override remote Pi dir
  --dry-run               Show what would sync without changing files
  --backup                Create timestamped backups before overwriting
  --delete                Delete extra files in destination directories
  --verbose               Show rsync commands and extra detail
  -h, --help              Show this help

OpenCode parts:
  auth, config, commands, skills, plugins

Pi parts:
  auth, settings, models, keybindings, extensions, skills,
  prompts, themes, agentsmd, sessions

Part shortcuts:
  default   Non-secret config only
  all       Everything for the selected agent(s), including auth and sessions

Examples:
  $SCRIPT_NAME list
  $SCRIPT_NAME paths --agent opencode
  $SCRIPT_NAME push --host user@newbox --agent all --part default --dry-run
  $SCRIPT_NAME push --host user@newbox --agent pi --part auth
  $SCRIPT_NAME pull --host user@oldbox --agent opencode --part config,skills

Notes:
  - Auth is opt-in: it is not included by the default part set.
  - Pi uses PI_CODING_AGENT_DIR locally when set.
  - OpenCode config location is auto-detected from known variants.
EOF
}

log() {
    printf '%s\n' "$*"
}

warn() {
    printf 'warning: %s\n' "$*" >&2
}

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

trim_spaces() {
    local value="$1"
    value=$(printf '%s' "$value" | tr -d '[:space:]')
    printf '%s\n' "$value"
}

split_csv() {
    local input="$1"
    local pieces=()
    local piece

    IFS=',' read -r -a pieces <<< "$input"
    for piece in "${pieces[@]}"; do
        piece=$(trim_spaces "$piece")
        if [[ -n "$piece" ]]; then
            printf '%s\n' "$piece"
        fi
    done
}

shell_quote() {
    local value="$1"
    value=${value//\'/\'\\\'\'}
    printf "'%s'" "$value"
}

run_local() {
    if (( DRY_RUN )); then
        log "DRY-RUN local: $*"
    else
        "$@"
    fi
}

run_remote_cmd() {
    local command="$1"
    if (( DRY_RUN )); then
        log "DRY-RUN remote[$HOST]: $command"
    else
        ssh "$HOST" "$command"
    fi
}

capture_remote() {
    local command="$1"
    ssh "$HOST" "$command"
}

local_exists() {
    local path="$1"
    [[ -e "$path" ]]
}

remote_exists() {
    local path="$1"
    ssh "$HOST" "[ -e $(shell_quote "$path") ]"
}

validate_agent() {
    case "$1" in
        opencode|pi|all) ;;
        *) die "Unsupported agent: $1" ;;
    esac
}

validate_part_for_agent() {
    local agent="$1"
    local part="$2"
    case "$agent:$part" in
        opencode:auth|opencode:config|opencode:commands|opencode:skills|opencode:plugins) ;;
        pi:auth|pi:settings|pi:models|pi:keybindings|pi:extensions|pi:skills|pi:prompts|pi:themes|pi:agentsmd|pi:sessions) ;;
        *) die "Part '$part' is not valid for agent '$agent'" ;;
    esac
}

part_is_dir() {
    case "$1:$2" in
        opencode:commands|opencode:skills|opencode:plugins) return 0 ;;
        pi:extensions|pi:skills|pi:prompts|pi:themes|pi:sessions) return 0 ;;
        *) return 1 ;;
    esac
}

expand_agents() {
    local token
    local saw_any=0

    while IFS= read -r token; do
        saw_any=1
        validate_agent "$token"
        if [[ "$token" == "all" ]]; then
            printf '%s\n' opencode pi
        else
            printf '%s\n' "$token"
        fi
    done < <(split_csv "$AGENT_ARG")

    if [[ "$saw_any" -eq 0 ]]; then
        die "No agents selected"
    fi
}

print_default_parts() {
    local agent="$1"
    if [[ "$agent" == "opencode" ]]; then
        printf '%s\n' config commands skills plugins
    else
        printf '%s\n' settings models keybindings extensions skills prompts themes agentsmd
    fi
}

print_all_parts() {
    local agent="$1"
    if [[ "$agent" == "opencode" ]]; then
        printf '%s\n' config commands skills plugins auth
    else
        printf '%s\n' settings models keybindings extensions skills prompts themes agentsmd auth sessions
    fi
}

expand_parts_for_agent() {
    local agent="$1"
    local token
    local saw_any=0

    while IFS= read -r token; do
        saw_any=1
        case "$token" in
            default)
                print_default_parts "$agent"
                ;;
            all)
                print_all_parts "$agent"
                ;;
            *)
                validate_part_for_agent "$agent" "$token"
                printf '%s\n' "$token"
                ;;
        esac
    done < <(split_csv "$PART_ARG")

    if [[ "$saw_any" -eq 0 ]]; then
        die "No parts selected for agent '$agent'"
    fi
}

opencode_config_path_from_key() {
    local home_dir="$1"
    local key="$2"
    case "$key" in
        1) printf '%s/.config/opencode/opencode.json\n' "$home_dir" ;;
        2) printf '%s/.config/opencode/opencode.jsonc\n' "$home_dir" ;;
        3) printf '%s/.opencode.json\n' "$home_dir" ;;
        4) printf '%s/.config/opencode/.opencode.json\n' "$home_dir" ;;
        *) die "Unknown OpenCode config key: $key" ;;
    esac
}

resolve_local_opencode_config() {
    local key
    local path

    for key in 1 2 3 4; do
        path=$(opencode_config_path_from_key "$HOME" "$key")
        if [[ -e "$path" ]]; then
            printf '%s|%s|yes\n' "$key" "$path"
            return 0
        fi
    done

    path=$(opencode_config_path_from_key "$HOME" 1)
    printf '1|%s|no\n' "$path"
}

resolve_remote_opencode_config() {
    local preferred_key="${1:-1}"
    local key
    local path

    for key in 1 2 3 4; do
        path=$(opencode_config_path_from_key "$REMOTE_HOME" "$key")
        if remote_exists "$path"; then
            printf '%s|%s|yes\n' "$key" "$path"
            return 0
        fi
    done

    path=$(opencode_config_path_from_key "$REMOTE_HOME" "$preferred_key")
    printf '%s|%s|no\n' "$preferred_key" "$path"
}

resolve_local_path() {
    local agent="$1"
    local part="$2"
    case "$agent:$part" in
        opencode:auth) printf '%s/.local/share/opencode/auth.json\n' "$HOME" ;;
        opencode:commands) printf '%s/.config/opencode/commands\n' "$HOME" ;;
        opencode:skills) printf '%s/.config/opencode/skills\n' "$HOME" ;;
        opencode:plugins) printf '%s/.config/opencode/plugins\n' "$HOME" ;;
        pi:auth) printf '%s/auth.json\n' "$LOCAL_PI_DIR" ;;
        pi:settings) printf '%s/settings.json\n' "$LOCAL_PI_DIR" ;;
        pi:models) printf '%s/models.json\n' "$LOCAL_PI_DIR" ;;
        pi:keybindings) printf '%s/keybindings.json\n' "$LOCAL_PI_DIR" ;;
        pi:extensions) printf '%s/extensions\n' "$LOCAL_PI_DIR" ;;
        pi:skills) printf '%s/skills\n' "$LOCAL_PI_DIR" ;;
        pi:prompts) printf '%s/prompts\n' "$LOCAL_PI_DIR" ;;
        pi:themes) printf '%s/themes\n' "$LOCAL_PI_DIR" ;;
        pi:agentsmd) printf '%s/AGENTS.md\n' "$LOCAL_PI_DIR" ;;
        pi:sessions) printf '%s/sessions\n' "$LOCAL_PI_DIR" ;;
        *) die "Cannot resolve local path for $agent:$part" ;;
    esac
}

resolve_remote_path() {
    local agent="$1"
    local part="$2"
    case "$agent:$part" in
        opencode:auth) printf '%s/.local/share/opencode/auth.json\n' "$REMOTE_HOME" ;;
        opencode:commands) printf '%s/.config/opencode/commands\n' "$REMOTE_HOME" ;;
        opencode:skills) printf '%s/.config/opencode/skills\n' "$REMOTE_HOME" ;;
        opencode:plugins) printf '%s/.config/opencode/plugins\n' "$REMOTE_HOME" ;;
        pi:auth) printf '%s/auth.json\n' "$REMOTE_PI_DIR" ;;
        pi:settings) printf '%s/settings.json\n' "$REMOTE_PI_DIR" ;;
        pi:models) printf '%s/models.json\n' "$REMOTE_PI_DIR" ;;
        pi:keybindings) printf '%s/keybindings.json\n' "$REMOTE_PI_DIR" ;;
        pi:extensions) printf '%s/extensions\n' "$REMOTE_PI_DIR" ;;
        pi:skills) printf '%s/skills\n' "$REMOTE_PI_DIR" ;;
        pi:prompts) printf '%s/prompts\n' "$REMOTE_PI_DIR" ;;
        pi:themes) printf '%s/themes\n' "$REMOTE_PI_DIR" ;;
        pi:agentsmd) printf '%s/AGENTS.md\n' "$REMOTE_PI_DIR" ;;
        pi:sessions) printf '%s/sessions\n' "$REMOTE_PI_DIR" ;;
        *) die "Cannot resolve remote path for $agent:$part" ;;
    esac
}

ensure_remote_state() {
    if [[ -n "$REMOTE_HOME_OVERRIDE" ]]; then
        REMOTE_HOME="$REMOTE_HOME_OVERRIDE"
    else
        REMOTE_HOME=$(capture_remote 'printf %s "$HOME"')
    fi

    if [[ -n "$REMOTE_PI_DIR_OVERRIDE" ]]; then
        REMOTE_PI_DIR="$REMOTE_PI_DIR_OVERRIDE"
    else
        REMOTE_PI_DIR=$(capture_remote 'printf %s "${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}"')
    fi
}

check_dependencies() {
    command -v rsync >/dev/null 2>&1 || die "rsync is required"

    if [[ "$COMMAND" == "push" || "$COMMAND" == "pull" ]]; then
        command -v ssh >/dev/null 2>&1 || die "ssh is required"
    fi

    if [[ "$COMMAND" == "paths" && -n "$HOST" ]]; then
        command -v ssh >/dev/null 2>&1 || die "ssh is required"
    fi
}

print_list() {
    cat <<EOF
Supported agents and parts

opencode
  default: config commands skills plugins
  all:     config commands skills plugins auth

pi
  default: settings models keybindings extensions skills prompts themes agentsmd
  all:     settings models keybindings extensions skills prompts themes agentsmd auth sessions
EOF
}

parent_dir() {
    local path="$1"
    dirname "$path"
}

print_paths() {
    local agent
    local part
    local local_path
    local local_exists_flag
    local remote_path
    local remote_exists_flag
    local config_info
    local config_key

    if [[ -n "$HOST" ]]; then
        ensure_remote_state
    fi

    while IFS= read -r agent; do
        log "Agent: $agent"
        while IFS= read -r part; do
            if [[ "$agent:$part" == "opencode:config" ]]; then
                config_info=$(resolve_local_opencode_config)
                IFS='|' read -r config_key local_path local_exists_flag <<< "$config_info"
            else
                local_path=$(resolve_local_path "$agent" "$part")
                if local_exists "$local_path"; then
                    local_exists_flag="yes"
                else
                    local_exists_flag="no"
                fi
            fi

            log "  $part"
            log "    local : $local_path [$local_exists_flag]"

            if [[ -n "$HOST" ]]; then
                if [[ "$agent:$part" == "opencode:config" ]]; then
                    config_info=$(resolve_remote_opencode_config "$config_key")
                    IFS='|' read -r _ remote_path remote_exists_flag <<< "$config_info"
                else
                    remote_path=$(resolve_remote_path "$agent" "$part")
                    if remote_exists "$remote_path"; then
                        remote_exists_flag="yes"
                    else
                        remote_exists_flag="no"
                    fi
                fi
                log "    remote: $remote_path [$remote_exists_flag]"
            fi
        done < <(expand_parts_for_agent "$agent")
        log ""
    done < <(expand_agents)
}

backup_local_destination() {
    local path="$1"
    local backup_path="$path.bak.$TIMESTAMP"
    if [[ -e "$path" ]]; then
        run_local cp -a "$path" "$backup_path"
        log "  backup: $backup_path"
    fi
}

backup_remote_destination() {
    local path="$1"
    local backup_path="$path.bak.$TIMESTAMP"
    if remote_exists "$path"; then
        run_remote_cmd "cp -a $(shell_quote "$path") $(shell_quote "$backup_path")"
        log "  backup: $backup_path"
    fi
}

mkdir_local_for_destination() {
    local path="$1"
    local agent="$2"
    local part="$3"
    if part_is_dir "$agent" "$part"; then
        run_local mkdir -p "$path"
    else
        run_local mkdir -p "$(parent_dir "$path")"
    fi
}

mkdir_remote_for_destination() {
    local path="$1"
    local agent="$2"
    local part="$3"
    if part_is_dir "$agent" "$part"; then
        run_remote_cmd "mkdir -p $(shell_quote "$path")"
    else
        run_remote_cmd "mkdir -p $(shell_quote "$(parent_dir "$path")")"
    fi
}

run_rsync() {
    local src="$1"
    local dst="$2"
    local is_dir="$3"
    local args=(-a)

    if (( VERBOSE )); then
        args+=(-v)
    fi
    if (( DRY_RUN )); then
        args+=(--dry-run)
    fi
    if (( DELETE_MODE )) && [[ "$is_dir" == "yes" ]]; then
        args+=(--delete)
    fi

    if (( VERBOSE )) || (( DRY_RUN )); then
        printf '  rsync:'
        printf ' %q' rsync "${args[@]}" "$src" "$dst"
        printf '\n'
    fi

    rsync "${args[@]}" "$src" "$dst"
}

sync_one() {
    local direction="$1"
    local agent="$2"
    local part="$3"
    local source_path=""
    local source_exists_flag="no"
    local dest_path=""
    local config_info
    local config_key="1"
    local is_dir="no"

    if part_is_dir "$agent" "$part"; then
        is_dir="yes"
    fi

    if [[ "$direction" == "push" ]]; then
        if [[ "$agent:$part" == "opencode:config" ]]; then
            config_info=$(resolve_local_opencode_config)
            IFS='|' read -r config_key source_path source_exists_flag <<< "$config_info"
            config_info=$(resolve_remote_opencode_config "$config_key")
            IFS='|' read -r _ dest_path _ <<< "$config_info"
        else
            source_path=$(resolve_local_path "$agent" "$part")
            if local_exists "$source_path"; then
                source_exists_flag="yes"
            fi
            dest_path=$(resolve_remote_path "$agent" "$part")
        fi
    else
        if [[ "$agent:$part" == "opencode:config" ]]; then
            config_info=$(resolve_remote_opencode_config 1)
            IFS='|' read -r config_key source_path source_exists_flag <<< "$config_info"
            config_info=$(resolve_local_opencode_config)
            IFS='|' read -r _ dest_path _ <<< "$config_info"
            if [[ ! -e "$dest_path" ]]; then
                dest_path=$(opencode_config_path_from_key "$HOME" "$config_key")
            fi
        else
            source_path=$(resolve_remote_path "$agent" "$part")
            if remote_exists "$source_path"; then
                source_exists_flag="yes"
            fi
            dest_path=$(resolve_local_path "$agent" "$part")
        fi
    fi

    log "$agent:$part"
    log "  source: $source_path"
    log "  dest  : $dest_path"

    if [[ "$source_exists_flag" != "yes" ]]; then
        warn "Skipping $agent:$part because the source path does not exist"
        return 0
    fi

    if (( BACKUP )); then
        if [[ "$direction" == "push" ]]; then
            backup_remote_destination "$dest_path"
        else
            backup_local_destination "$dest_path"
        fi
    fi

    if [[ "$direction" == "push" ]]; then
        mkdir_remote_for_destination "$dest_path" "$agent" "$part"
        if [[ "$is_dir" == "yes" ]]; then
            run_rsync "${source_path%/}/" "$HOST:${dest_path%/}/" "$is_dir"
        else
            run_rsync "$source_path" "$HOST:$dest_path" "$is_dir"
        fi
    else
        mkdir_local_for_destination "$dest_path" "$agent" "$part"
        if [[ "$is_dir" == "yes" ]]; then
            run_rsync "$HOST:${source_path%/}/" "${dest_path%/}/" "$is_dir"
        else
            run_rsync "$HOST:$source_path" "$dest_path" "$is_dir"
        fi
    fi
}

sync_all() {
    local direction="$1"
    local agent
    local part

    ensure_remote_state

    log "Remote home   : $REMOTE_HOME"
    log "Remote Pi dir : $REMOTE_PI_DIR"
    log "Local Pi dir  : $LOCAL_PI_DIR"
    log ""

    while IFS= read -r agent; do
        while IFS= read -r part; do
            sync_one "$direction" "$agent" "$part"
        done < <(expand_parts_for_agent "$agent")
    done < <(expand_agents)
}

parse_args() {
    if [[ $# -eq 0 ]]; then
        usage
        exit 0
    fi

    COMMAND="$1"
    shift

    case "$COMMAND" in
        list|paths|push|pull) ;;
        -h|--help) usage; exit 0 ;;
        *) die "Unknown command: $COMMAND" ;;
    esac

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --host)
                [[ $# -ge 2 ]] || die "--host requires a value"
                HOST="$2"
                shift 2
                ;;
            --agent)
                [[ $# -ge 2 ]] || die "--agent requires a value"
                AGENT_ARG="$2"
                shift 2
                ;;
            --part)
                [[ $# -ge 2 ]] || die "--part requires a value"
                PART_ARG="$2"
                shift 2
                ;;
            --remote-home)
                [[ $# -ge 2 ]] || die "--remote-home requires a value"
                REMOTE_HOME_OVERRIDE="$2"
                shift 2
                ;;
            --remote-pi-dir)
                [[ $# -ge 2 ]] || die "--remote-pi-dir requires a value"
                REMOTE_PI_DIR_OVERRIDE="$2"
                shift 2
                ;;
            --dry-run)
                DRY_RUN=1
                shift
                ;;
            --verbose)
                VERBOSE=1
                shift
                ;;
            --backup)
                BACKUP=1
                shift
                ;;
            --delete)
                DELETE_MODE=1
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                die "Unknown option: $1"
                ;;
        esac
    done

    if [[ "$COMMAND" == "push" || "$COMMAND" == "pull" ]]; then
        [[ -n "$HOST" ]] || die "--host is required for $COMMAND"
    fi
}

main() {
    parse_args "$@"
    check_dependencies

    case "$COMMAND" in
        list)
            print_list
            ;;
        paths)
            print_paths
            ;;
        push)
            sync_all push
            ;;
        pull)
            sync_all pull
            ;;
    esac
}

main "$@"
