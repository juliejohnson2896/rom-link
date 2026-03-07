#!/bin/bash
# =============================================================================
# rom-link.sh
# Builds symlink-based ROM directory structures for target OS layouts.
# Uses external config files per OS — no data is duplicated.
#
# Usage:
#   ./rom-link.sh [options] <config_file> [config_file2 ...]
#
# Options:
#   -d, --dry-run       Preview all actions without making any changes
#   -l, --log <file>    Write output to a log file (in addition to stdout)
#   -v, --verbose       Show every file linked, not just directory summaries
#   -h, --help          Show this help message
#
# Examples:
#   ./rom-link.sh configs/batocera.conf
#   ./rom-link.sh --dry-run configs/batocera.conf
#   ./rom-link.sh --log /var/log/rom-link.log configs/batocera.conf configs/emudeck.conf
# =============================================================================

set -euo pipefail

# --- Defaults -----------------------------------------------------------------
DRY_RUN=false
VERBOSE=false
LOG_FILE=""
CONFIGS=()

# --- Counters -----------------------------------------------------------------
TOTAL_LINKED=0
TOTAL_SKIPPED=0
TOTAL_UPDATED=0
TOTAL_ERRORS=0

# =============================================================================
# Logging
# =============================================================================
log() {
  local LEVEL="$1"
  shift
  local MSG="[$(date '+%Y-%m-%d %H:%M:%S')] [$LEVEL] $*"
  echo "$MSG"
  if [ -n "$LOG_FILE" ]; then
    echo "$MSG" >> "$LOG_FILE"
  fi
}

info()    { log "INFO " "$@"; }
warn()    { log "WARN " "$@"; }
error()   { log "ERROR" "$@"; TOTAL_ERRORS=$((TOTAL_ERRORS + 1)); }
verbose() { if $VERBOSE; then log "DEBUG" "$@"; fi; }
dry()     { log "DRY  " "$@"; }

# =============================================================================
# Usage
# =============================================================================
usage() {
  sed -n '/^# Usage:/,/^# =====/{ /^# =====/d; s/^# \{0,1\}//; p }' "$0"
  exit 0
}

# =============================================================================
# Argument Parsing
# =============================================================================
parse_args() {
  if [ $# -eq 0 ]; then
    usage
  fi

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -d|--dry-run)
        DRY_RUN=true
        shift
        ;;
      -v|--verbose)
        VERBOSE=true
        shift
        ;;
      -l|--log)
        LOG_FILE="$2"
        shift 2
        ;;
      -h|--help)
        usage
        ;;
      -*)
        echo "Unknown option: $1"
        usage
        ;;
      *)
        CONFIGS+=("$1")
        shift
        ;;
    esac
  done

  if [ ${#CONFIGS[@]} -eq 0 ]; then
    echo "Error: No config file(s) specified."
    usage
  fi
}

# =============================================================================
# Config Loader
# Parses a .conf file and sets global variables:
#   CANONICAL_ROOT, TARGET_ROOT, OS_NAME
#   and populates the MAP associative array
# =============================================================================
declare -A MAP

load_config() {
  local CONFIG_FILE="$1"

  if [ ! -f "$CONFIG_FILE" ]; then
    error "Config file not found: $CONFIG_FILE"
    return 1
  fi

  # Reset MAP for each config
  unset MAP
  declare -gA MAP

  OS_NAME=""
  CANONICAL_ROOT=""
  TARGET_ROOT=""

  local IN_SYSTEMS=false

  while IFS= read -r LINE || [[ -n "$LINE" ]]; do
    # Strip inline comments and blank lines
    LINE="${LINE%%#*}"
    # Trim leading and trailing whitespace only — preserve internal spaces in paths
    LINE="${LINE#"${LINE%%[![:space:]]*}"}"
    LINE="${LINE%"${LINE##*[![:space:]]}"}"
    [[ -z "$LINE" ]] && continue

    # Section header
    if [[ "$LINE" == "[systems]" ]]; then
      IN_SYSTEMS=true
      continue
    elif [[ "$LINE" == "["* ]]; then
      IN_SYSTEMS=false
      continue
    fi

    if $IN_SYSTEMS; then
      # Format: dest_name = source/relative/path : mode
      # Use regex that allows spaces inside path and trims around = and :
      if [[ "$LINE" =~ ^([^=]+)[[:space:]]*=[[:space:]]*(.+)[[:space:]]*:[[:space:]]*(flat|recursive|dir)[[:space:]]*$ ]]; then
        local KEY="${BASH_REMATCH[1]}"
        local VAL="${BASH_REMATCH[2]}"
        local MODE="${BASH_REMATCH[3]}"
        # Trim trailing whitespace from KEY and VAL
        KEY="${KEY%"${KEY##*[![:space:]]}"}"
        VAL="${VAL%"${VAL##*[![:space:]]}"}"
        MAP["$KEY"]="${VAL}:${MODE}"
      fi
    else
      # Key=value pairs — trim whitespace around = but preserve spaces in value
      if [[ "$LINE" =~ ^([^=]+)[[:space:]]*=[[:space:]]*(.+)$ ]]; then
        local K="${BASH_REMATCH[1]}"
        local V="${BASH_REMATCH[2]}"
        # Trim trailing whitespace from key and value
        K="${K%"${K##*[![:space:]]}"}"
        V="${V%"${V##*[![:space:]]}"}"
        case "$K" in
          os_name)        OS_NAME="$V" ;;
          canonical_root) CANONICAL_ROOT="$V" ;;
          target_root)    TARGET_ROOT="$V" ;;
        esac
      fi
    fi
  done < "$CONFIG_FILE"

  # Validate required fields
  local VALID=true
  [[ -z "$OS_NAME" ]]        && { error "Config missing: os_name"; VALID=false; }
  [[ -z "$CANONICAL_ROOT" ]] && { error "Config missing: canonical_root"; VALID=false; }
  [[ -z "$TARGET_ROOT" ]]    && { error "Config missing: target_root"; VALID=false; }
  [[ ${#MAP[@]} -eq 0 ]]     && { error "Config has no [systems] entries"; VALID=false; }

  $VALID || return 1

  info "Loaded config: $CONFIG_FILE (OS: $OS_NAME)"
  info "  Canonical root : $CANONICAL_ROOT"
  info "  Target root    : $TARGET_ROOT"
  info "  Systems defined: ${#MAP[@]}"
}

# =============================================================================
# Symlink a single file
# =============================================================================
link_file() {
  local SRC="$1"
  local DEST="$2"
  local FILENAME
  FILENAME=$(basename "$SRC")

  # Real file exists (OS-managed) — do not overwrite
  if [ -e "$DEST" ] && [ ! -L "$DEST" ]; then
    verbose "SKIP (OS-managed): $DEST"
    TOTAL_SKIPPED=$((TOTAL_SKIPPED + 1))
    return
  fi

  # Symlink already exists and points to correct target — no update needed
  if [ -L "$DEST" ] && [ "$(readlink "$DEST")" = "$SRC" ]; then
    verbose "SKIP (current): $DEST"
    TOTAL_SKIPPED=$((TOTAL_SKIPPED + 1))
    return
  fi

  # Symlink exists but points somewhere else — update it
  if [ -L "$DEST" ]; then
    if $DRY_RUN; then
      dry "UPDATE link: $DEST -> $SRC"
    else
      ln -sf "$SRC" "$DEST"
      verbose "UPDATED: $DEST -> $SRC"
    fi
    TOTAL_UPDATED=$((TOTAL_UPDATED + 1))
    return
  fi

  # New link
  if $DRY_RUN; then
    dry "LINK: $DEST -> $SRC"
  else
    ln -sf "$SRC" "$DEST"
    verbose "LINKED: $DEST -> $SRC"
  fi
  TOTAL_LINKED=$((TOTAL_LINKED + 1))
}

# =============================================================================
# Link all files in a single directory (flat, no recursion)
# =============================================================================
link_files_in_dir() {
  local SRC_DIR="$1"
  local DEST_DIR="$2"

  if $DRY_RUN; then
    dry "mkdir -p $DEST_DIR"
  else
    mkdir -p "$DEST_DIR"
  fi

  while IFS= read -r FILE; do
    link_file "$FILE" "${DEST_DIR}/$(basename "$FILE")"
  done < <(find "$SRC_DIR" -maxdepth 1 -type f)
}

# =============================================================================
# Recursively mirror directory tree, linking files at each level
# =============================================================================
link_recursive() {
  local SRC_DIR="$1"
  local DEST_DIR="$2"

  # Link files at this level
  link_files_in_dir "$SRC_DIR" "$DEST_DIR"

  # Recurse into subdirectories (skip hidden dirs)
  while IFS= read -r SUBDIR; do
    local DIRNAME
    DIRNAME=$(basename "$SUBDIR")
    [[ "$DIRNAME" == .* ]] && continue
    link_recursive "$SUBDIR" "${DEST_DIR}/${DIRNAME}"
  done < <(find "$SRC_DIR" -maxdepth 1 -mindepth 1 -type d)
}

# =============================================================================
# Process a single OS config
# =============================================================================
process_config() {
  local CONFIG_FILE="$1"

  load_config "$CONFIG_FILE" || return 1

  info "--- Processing OS: $OS_NAME ---"
  $DRY_RUN && info "*** DRY RUN MODE — no changes will be made ***"

  for DEST in "${!MAP[@]}"; do
    # Use a pipe as internal delimiter since colon could appear in paths on some systems
    # MAP stores values as "src_path:mode" — split on the LAST colon to get mode
    local ENTRY="${MAP[$DEST]}"
    local DEPTH="${ENTRY##*:}"
    local SRC_REL="${ENTRY%:*}"
    local SRC="${CANONICAL_ROOT}/${SRC_REL}"
    local LINK_DIR="${TARGET_ROOT}/${DEST}"

    if [ ! -d "$SRC" ]; then
      warn "Source not found, skipping: $SRC"
      continue
    fi

    case "$DEPTH" in
      flat)
        info "[$DEST] Mode: flat"
        link_files_in_dir "$SRC" "$LINK_DIR"
        ;;
      recursive)
        info "[$DEST] Mode: recursive"
        link_recursive "$SRC" "$LINK_DIR"
        ;;
      dir)
        info "[$DEST] Mode: dir (directory-level symlink)"
        if $DRY_RUN; then
          dry "ln -sfn $SRC $LINK_DIR"
        else
          ln -sfn "$SRC" "$LINK_DIR"
        fi
        ;;
      *)
        warn "Unknown mode '$DEPTH' for system '$DEST' — skipping"
        ;;
    esac
  done

  info "--- Done: $OS_NAME ---"
}

# =============================================================================
# Summary Report
# =============================================================================
print_summary() {
  echo ""
  info "=============================="
  info " ROM Link Summary"
  info "=============================="
  $DRY_RUN && info " Mode        : DRY RUN (no changes made)"
  info " New links   : $TOTAL_LINKED"
  info " Updated     : $TOTAL_UPDATED"
  info " Skipped     : $TOTAL_SKIPPED"
  info " Errors      : $TOTAL_ERRORS"
  [ -n "$LOG_FILE" ] && info " Log file    : $LOG_FILE"
  info "=============================="
}

# =============================================================================
# Entry Point
# =============================================================================
main() {
  parse_args "$@"

  # Initialize log file
  if [ -n "$LOG_FILE" ]; then
    mkdir -p "$(dirname "$LOG_FILE")"
    echo "# rom-link.sh log — $(date)" > "$LOG_FILE"
  fi

  for CONFIG in "${CONFIGS[@]}"; do
    process_config "$CONFIG"
  done

  print_summary

  [ "$TOTAL_ERRORS" -gt 0 ] && exit 1
  exit 0
}

main "$@"
