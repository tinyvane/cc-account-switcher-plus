#!/usr/bin/env bash
# Multi-Account Switcher for Claude Code (Cygwin-aware)
# - Detect CYGWIN/MINGW/MSYS as 'cygwin'
# - Better path discovery for Cygwin: /cygdrive/c/Users/$USER/.claude.json (and lowercase users)
# - Honor CLAUDE_CONFIG_DIR for both .claude.json and .credentials.json
# - add --debug and --doctor for troubleshooting

set -euo pipefail
# 记录本次检测到的凭据实际路径（read_credentials 会设置）
CREDS_PATH_FOUND=""



# ---------- Debug ----------
CCS_DEBUG="${CCS_DEBUG:-0}" # 0 off, 1 logs, 2 logs+set -x
dbg() { [[ "$CCS_DEBUG" != "0" ]] && echo "[DEBUG] $*" >&2 || true; }
die() { echo "[ERROR] $*" >&2; exit 1; }
if [[ "${1:-}" == "--debug" ]]; then CCS_DEBUG="${CCS_DEBUG:-1}"; shift; fi
[[ "$CCS_DEBUG" == "2" ]] && set -x

# ---------- Config ----------
readonly BACKUP_DIR="$HOME/.claude-switch-backup"
readonly SEQUENCE_FILE="$BACKUP_DIR/sequence.json"

# ---------- Container ----------
is_running_in_container() {
  [[ -f /.dockerenv ]] && return 0
  [[ -f /proc/1/cgroup ]] && grep -q 'docker\|lxc\|containerd\|kubepods' /proc/1/cgroup 2>/dev/null && return 0
  [[ -f /proc/self/mountinfo ]] && grep -q 'docker\|overlay' /proc/self/mountinfo 2>/dev/null && return 0
  [[ -n "${CONTAINER:-}" || -n "${container:-}" ]] && return 0
  return 1
}

# ---------- Platform ----------
detect_platform() {
  case "$(uname -s)" in
    Darwin) echo "macos" ;;
    Linux)  [[ -n "${WSL_DISTRO_NAME:-}" ]] && echo "wsl" || echo "linux" ;;
    CYGWIN*|MINGW*|MSYS*) echo "cygwin" ;;
    *) echo "unknown" ;;
  esac
}

# ---------- Windows path helpers for Cygwin ----------
to_cyg_path() { # convert like C:\Users\xx -> /cygdrive/c/Users/xx
  local win="$1"
  # already a cyg path
  [[ "$win" =~ ^/cygdrive/ ]] && { echo "$win"; return; }
  # C:\Users\xx  or  c:\users\xx
  if [[ "$win" =~ ^[A-Za-z]:\\ ]]; then
    local drive="${win:0:1}"
    local tail="${win:3}"
    tail="${tail//\\//}"
    echo "/cygdrive/${drive,,}/$tail"
    return
  fi
  echo "$win"
}

# 判断目录里是否有任何 Claude 相关文件
_have_any_claude_files() {
  local d="$1"
  [[ -f "$d/.claude.json" || -f "$d/.credentials.json" || -f "$d/.claude/.claude.json" || -f "$d/.claude/.credentials.json" ]]
}

# 猜 Windows 用户根（转成 cyg 路径）
_guess_windows_root() {
  local wr=""
  if [[ -n "${USERPROFILE:-}" ]]; then
    wr="$(to_cyg_path "$USERPROFILE")"
    [[ -n "$wr" && -d "$wr" ]] && echo "$wr" && return
  fi
  for d in "/cygdrive/c/Users/$USER" "/cygdrive/c/users/$USER"; do
    [[ -d "$d" ]] && echo "$d" && return
  done
  echo ""
}


# ---------- Path discovery ----------
get_config_dir() {
  # 1) 明确指定优先
  if [[ -n "${CLAUDE_CONFIG_DIR:-}" ]]; then
    echo "$CLAUDE_CONFIG_DIR"; return
  fi

  local platform; platform=$(detect_platform)
  local home_dot="$HOME/.claude"

  if [[ "$platform" == "cygwin" ]]; then
    # 2) 先看 Windows 用户根（只有存在任一 Claude 文件才采用）
    local wr; wr="$(_guess_windows_root)"
    if [[ -n "$wr" && "$(_have_any_claude_files "$wr" && echo yes || echo no)" == "yes" ]]; then
      echo "$wr"; return
    fi

    # 3) 再看 ~/.claude（只有有文件才采用；不再因为“目录存在”就优先）
    if [[ "$(_have_any_claude_files "$home_dot" && echo yes || echo no)" == "yes" ]]; then
      echo "$home_dot"; return
    fi

    # 4) 兜底：优先返回 Windows 根（即使里面目前没文件），否则 ~/.claude
    [[ -n "$wr" ]] && { echo "$wr"; return; }
    echo "$home_dot"; return
  fi

  # 非 cygwin：保持原样
  echo "$home_dot"
}



# Final config json path (prefers one that has .oauthAccount)
get_claude_config_path() {
  local dir; dir="$(get_config_dir)"
  local cand=(
    "$dir/.claude.json"              # Windows 用户根平铺
    "$dir/.claude/.claude.json"      # Windows 用户根下 .claude 子目录
    "$HOME/.claude/.claude.json"     # 传统路径
    "$HOME/.claude.json"             # 传统平铺
  )

  # 在 cygwin 再显式补充 Windows 根候选，防止 dir 判断失误时仍能命中
  if [[ "$(detect_platform)" == "cygwin" ]]; then
    local wr; wr="$(_guess_windows_root)"
    if [[ -n "$wr" ]]; then
      cand+=("$wr/.claude.json" "$wr/.claude/.claude.json")
    fi
  fi

  for f in "${cand[@]}"; do
    if [[ -f "$f" ]] && jq -e '.oauthAccount' "$f" >/dev/null 2>&1; then
      echo "$f"; return
    fi
  done
  # 兜底返回第一候选，便于后续写入
  echo "${cand[0]}"
}



get_credentials_path() {
  local dir; dir="$(get_config_dir)"
  local cand=(
    "$dir/.credentials.json"           # 平铺
    "$dir/.claude/.credentials.json"   # 子目录
    "$HOME/.claude/.credentials.json"  # 传统
  )

  if [[ "$(detect_platform)" == "cygwin" ]]; then
    local wr; wr="$(_guess_windows_root)"
    if [[ -n "$wr" ]]; then
      cand+=("$wr/.credentials.json" "$wr/.claude/.credentials.json")
    fi
  fi

  for f in "${cand[@]}"; do
    [[ -f "$f" ]] && { echo "$f"; return; }
  done
  # 若都不存在，默认返回 Windows 常见的子目录路径
  if [[ -n "${wr:-}" ]]; then
    echo "$wr/.claude/.credentials.json"
  else
    echo "$dir/.claude/.credentials.json"
  fi
}



# ---------- JSON helpers ----------
validate_json() { jq . "$1" >/dev/null 2>&1 || { echo "Error: Invalid JSON in $1"; return 1; }; }
validate_email() { [[ "$1" =~ ^[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}$ ]]; }

resolve_account_identifier() {
  local id="$1"
  if [[ "$id" =~ ^[0-9]+$ ]]; then echo "$id"; else
    jq -r --arg email "$id" '.accounts | to_entries[] | select(.value.email == $email) | .key' "$SEQUENCE_FILE" 2>/dev/null || true
  fi
}

write_json() {
  local file="$1" content="$2" tmp
  tmp=$(mktemp "${file}.XXXXXX")
  printf '%s' "$content" > "$tmp"
  jq . "$tmp" >/dev/null 2>&1 || { rm -f "$tmp"; die "Generated invalid JSON for $file"; }
  mv "$tmp" "$file"; chmod 600 "$file"
}

# ---------- Version & deps ----------
check_bash_version() {
  local v; v=$(bash --version | head -n1 | grep -oE '[0-9]+\.[0-9]+' | head -n1)
  dbg "bash version: $v"
  awk -v ver="$v" 'BEGIN{split(ver,a,".");exit ((a[1]>4 || (a[1]==4 && a[2]>=4))?0:1)}' || die "Bash 4.4+ required (found $v)"
}
check_dependencies() { command -v jq >/dev/null || die "Required 'jq' not found"; }

# ---------- Setup ----------
setup_directories() { mkdir -p "$BACKUP_DIR"/{configs,credentials}; chmod 700 "$BACKUP_DIR" "$BACKUP_DIR"/{configs,credentials}; }

# ---------- Claude process ----------
is_claude_running() { ps -eo pid,comm,args | awk '$2=="claude" || $3=="claude"{exit 0} END{exit 1}'; }
wait_for_claude_close() { is_claude_running || return 0; echo "Claude Code is running. Close it first."; while is_claude_running; do sleep 1; done; }

# ---------- Current account ----------
get_current_account() {
  local cfg; cfg="$(get_claude_config_path)"; dbg "current cfg: $cfg"
  [[ -f "$cfg" ]] || { dbg "cfg not found"; echo "none"; return; }
  validate_json "$cfg" || { dbg "cfg invalid json"; echo "none"; return; }
  local email; email=$(jq -r '.oauthAccount.emailAddress // empty' "$cfg" 2>/dev/null || true)
  [[ -n "$email" ]] && echo "$email" || echo "none"
}

# ---------- Credentials I/O ----------
# macOS uses Keychain; others use file
read_credentials() {
  local platform; platform=$(detect_platform)
  case "$platform" in
    macos)
      CREDS_PATH_FOUND=""
      security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null || \
      security find-generic-password -s "Claude Code" -w 2>/dev/null || echo ""
      ;;
    *)
      CREDS_PATH_FOUND=""
      # 遍历 get_credentials_path 的候选逻辑（与上面保持一致）
      local dir wr
      dir="$(get_config_dir)"
      wr="$(_guess_windows_root)"

      local cand=(
        "$dir/.credentials.json"
        "$dir/.claude/.credentials.json"
        "$HOME/.claude/.credentials.json"
      )
      [[ -n "$wr" ]] && cand+=("$wr/.credentials.json" "$wr/.claude/.credentials.json")

      for f in "${cand[@]}"; do
        if [[ -f "$f" ]]; then
          CREDS_PATH_FOUND="$f"
          cat "$f"
          return
        fi
      done
      echo ""
      ;;
  esac
}

write_credentials() {
  local credentials="$1" platform; platform=$(detect_platform)
  case "$platform" in
    macos)
      security add-generic-password -U -s "Claude Code-credentials" -a "$USER" -w "$credentials" 2>/dev/null
      ;;
    *)
      local target
      if [[ -n "${CREDS_PATH_FOUND:-}" ]]; then
        target="$CREDS_PATH_FOUND"       # 写回读到的原位置
      else
        # 没读到时，尽量遵循官方常见布局：Windows 用户根下的 .claude 子目录
        local dir wr
        dir="$(get_config_dir)"
        wr="$(_guess_windows_root)"
        if [[ -n "$wr" ]]; then
          target="$wr/.claude/.credentials.json"
        else
          target="$dir/.claude/.credentials.json"
        fi
      fi
      mkdir -p "$(dirname "$target")"
      printf '%s' "$credentials" > "$target"
      chmod 600 "$target"
      ;;
  esac
}


read_account_credentials() {
  local num="$1" email="$2" platform; platform=$(detect_platform)
  case "$platform" in
    macos) security find-generic-password -s "Claude Code-Account-${num}-${email}" -w 2>/dev/null || echo "" ;;
    *)     local f="$BACKUP_DIR/credentials/.claude-credentials-${num}-${email}.json"; [[ -f "$f" ]] && cat "$f" || echo "" ;;
  esac
}
write_account_credentials() {
  local num="$1" email="$2" creds="$3" platform; platform=$(detect_platform)
  case "$platform" in
    macos) security add-generic-password -U -s "Claude Code-Account-${num}-${email}" -a "$USER" -w "$creds" 2>/dev/null ;;
    *)     local f="$BACKUP_DIR/credentials/.claude-credentials-${num}-${email}.json"; printf '%s' "$creds" > "$f"; chmod 600 "$f" ;;
  esac
}

read_account_config()  { local f="$BACKUP_DIR/configs/.claude-config-$1-$2.json"; [[ -f "$f" ]] && cat "$f" || echo ""; }
write_account_config() { local f="$BACKUP_DIR/configs/.claude-config-$1-$2.json"; printf '%s' "$3" > "$f"; chmod 600 "$f"; }

# ---------- State ----------
init_sequence_file() {
  [[ -f "$SEQUENCE_FILE" ]] && return
  write_json "$SEQUENCE_FILE" '{
  "activeAccountNumber": null,
  "lastUpdated": "'$(date -u +%Y-%m-%dT%H:%M:%SZ)'",
  "sequence": [],
  "accounts": {}
}'
}
get_next_account_number() { [[ -f "$SEQUENCE_FILE" ]] || { echo 1; return; }; jq -r '.accounts | keys | map(tonumber) | max // 0' "$SEQUENCE_FILE" | awk '{print $1+1}'; }
account_exists() { [[ -f "$SEQUENCE_FILE" ]] || return 1; jq -e --arg email "$1" '.accounts[] | select(.email==$email)' "$SEQUENCE_FILE" >/dev/null 2>&1; }

# ---------- Commands ----------
cmd_add_account() {
  setup_directories; init_sequence_file
  local email; email=$(get_current_account)
  [[ "$email" != "none" ]] || die "Error: No active Claude account found. Please log in first."
  if account_exists "$email"; then echo "Account $email is already managed."; return 0; fi

  local num; num=$(get_next_account_number)
  local cfg; cfg="$(get_claude_config_path)"
  local creds; creds=$(read_credentials)
  [[ -n "$creds" ]] || die "Error: No credentials found for current account"

  local uuid; uuid=$(jq -r '.oauthAccount.accountUuid // empty' "$cfg")
  write_account_credentials "$num" "$email" "$creds"
  write_account_config "$num" "$email" "$(cat "$cfg")"

  local updated
  updated=$(jq --arg num "$num" --arg email "$email" --arg uuid "$uuid" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
    .accounts[$num] = { email: $email, uuid: $uuid, added: $now } |
    .sequence += [$num | tonumber] |
    .activeAccountNumber = ($num | tonumber) |
    .lastUpdated = $now
  ' "$SEQUENCE_FILE")
  write_json "$SEQUENCE_FILE" "$updated"
  echo "Added Account $num: $email"
}

cmd_remove_account() {
  [[ $# -gt 0 ]] || die "Usage: $0 --remove-account <num|email>"
  [[ -f "$SEQUENCE_FILE" ]] || die "Error: No accounts are managed yet"

  local id="$1" num
  if [[ "$id" =~ ^[0-9]+$ ]]; then num="$id"; else
    validate_email "$id" || die "Error: Invalid email format: $id"
    num="$(resolve_account_identifier "$id")"; [[ -n "$num" ]] || die "Error: No account found with email: $id"
  fi

  local info; info=$(jq -r --arg num "$num" '.accounts[$num] // empty' "$SEQUENCE_FILE")
  [[ -n "$info" ]] || die "Error: Account-$num does not exist"
  local email; email=$(echo "$info" | jq -r '.email')

  echo -n "Remove Account-$num ($email)? [y/N] "; read -r ok
  [[ "$ok" == "y" || "$ok" == "Y" ]] || { echo "Cancelled"; return 0; }

  rm -f "$BACKUP_DIR/credentials/.claude-credentials-${num}-${email}.json"
  rm -f "$BACKUP_DIR/configs/.claude-config-${num}-${email}.json"

  local updated
  updated=$(jq --arg num "$num" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
    del(.accounts[$num]) |
    .sequence = (.sequence | map(select(. != ($num | tonumber)))) |
    .lastUpdated = $now
  ' "$SEQUENCE_FILE")
  write_json "$SEQUENCE_FILE" "$updated"
  echo "Account-$num ($email) has been removed"
}

cmd_list() {
  if [[ ! -f "$SEQUENCE_FILE" ]]; then echo "No accounts are managed yet."; first_run_setup || true; return 0; fi
  local cur; cur=$(get_current_account)
  local active_num=""; [[ "$cur" != "none" ]] && active_num=$(jq -r --arg email "$cur" '.accounts | to_entries[] | select(.value.email==$email) | .key' "$SEQUENCE_FILE" 2>/dev/null || true)
  echo "Accounts:"
  jq -r --arg active "$active_num" '
    .sequence[] as $n |
    .accounts["\($n)"] |
    (("\($n): \(.email)") + (if "\($n)"==$active then " (active)" else "" end))
  ' "$SEQUENCE_FILE"
}

first_run_setup() {
  local email; email=$(get_current_account)
  [[ "$email" != "none" ]] || { echo "No active Claude account found. Please log in first."; return 1; }
  echo -n "No managed accounts found. Add current account ($email)? [Y/n] "; read -r r
  [[ "$r" == "n" || "$r" == "N" ]] && { echo "Cancelled."; return 1; }
  cmd_add_account
}

perform_switch() {
  local target="$1"
  local cur_num tgt_email cur_email
  cur_num=$(jq -r '.activeAccountNumber' "$SEQUENCE_FILE")
  tgt_email=$(jq -r --arg num "$target" '.accounts[$num].email' "$SEQUENCE_FILE")
  cur_email=$(get_current_account)

  local cur_creds cfgpath cur_cfg
  cur_creds=$(read_credentials)
  cfgpath="$(get_claude_config_path)"
  cur_cfg=$(cat "$cfgpath")

  write_account_credentials "$cur_num" "$cur_email" "$cur_creds"
  write_account_config "$cur_num" "$cur_email" "$cur_cfg"

  local tgt_creds tgt_cfg
  tgt_creds=$(read_account_credentials "$target" "$tgt_email")
  tgt_cfg=$(read_account_config "$target" "$tgt_email")
  [[ -n "$tgt_creds" && -n "$tgt_cfg" ]] || die "Error: Missing backup data for Account-$target"

  write_credentials "$tgt_creds"

  local oauth; oauth=$(echo "$tgt_cfg" | jq '.oauthAccount' 2>/dev/null)
  [[ -n "$oauth" && "$oauth" != "null" ]] || die "Error: Invalid oauthAccount in backup"
  local merged; merged=$(jq --argjson oauth "$oauth" '.oauthAccount = $oauth' "$cfgpath" 2>/dev/null) || die "Error: Failed to merge config"
  write_json "$cfgpath" "$merged"

  local upd; upd=$(jq --arg num "$target" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '.activeAccountNumber = ($num|tonumber) | .lastUpdated=$now' "$SEQUENCE_FILE")
  write_json "$SEQUENCE_FILE" "$upd"

  echo "Switched to Account-$target ($tgt_email)"
  cmd_list
  echo; echo "Please restart Claude Code to use the new authentication."; echo
}

cmd_switch() {
  [[ -f "$SEQUENCE_FILE" ]] || die "Error: No accounts are managed yet"
  local email; email=$(get_current_account); [[ "$email" != "none" ]] || die "Error: No active Claude account found"
  if ! account_exists "$email"; then
    echo "Notice: Active account '$email' was not managed."
    cmd_add_account
    local n; n=$(jq -r '.activeAccountNumber' "$SEQUENCE_FILE")
    echo "It has been automatically added as Account-$n."
    echo "Please run './ccswitch.sh --switch' again to switch to the next account."
    return 0
  fi
  local active; active=$(jq -r '.activeAccountNumber' "$SEQUENCE_FILE")
  mapfile -t seq < <(jq -r '.sequence[]' "$SEQUENCE_FILE")
  local idx=0; for i in "${!seq[@]}"; do [[ "${seq[i]}" == "$active" ]] && { idx=$i; break; }; done
  local next="${seq[$(((idx + 1) % ${#seq[@]}))]}"
  perform_switch "$next"
}

cmd_switch_to() {
  [[ $# -gt 0 ]] || die "Usage: $0 --switch-to <num|email>"
  [[ -f "$SEQUENCE_FILE" ]] || die "Error: No accounts are managed yet"
  local id="$1" target
  if [[ "$id" =~ ^[0-9]+$ ]]; then target="$id"; else
    validate_email "$id" || die "Error: Invalid email format: $id"
    target="$(resolve_account_identifier "$id")"; [[ -n "$target" ]] || die "Error: No account found with email: $id"
  fi
  local exists; exists=$(jq -r --arg num "$target" '.accounts[$num] // empty' "$SEQUENCE_FILE")
  [[ -n "$exists" ]] || die "Error: Account-$target does not exist"
  perform_switch "$target"
}

# ---------- Doctor (optional) ----------
cmd_doctor() {
  echo "=== doctor ==="
  echo "platform : $(detect_platform)"
  echo "HOME     : $HOME"
  echo "CLAUDE_CONFIG_DIR : ${CLAUDE_CONFIG_DIR:-<unset>}"
  local dir; dir="$(get_config_dir)"
  echo "config dir -> $dir"

  local wr; wr="$(_guess_windows_root)"
  [[ -n "$wr" ]] && echo "windows root guess -> $wr"

  local cfg; cfg="$(get_claude_config_path)"
  echo "config file-> $cfg (exists: $( [[ -f \"$cfg\" ]] && echo yes || echo no ))"

  echo "config candidates:"
  printf "  - %s\n" \
    "$dir/.claude.json" \
    "$dir/.claude/.claude.json" \
    "$HOME/.claude/.claude.json" \
    "$HOME/.claude.json" \
    ${wr:+$wr/.claude.json} \
    ${wr:+$wr/.claude/.claude.json}

  echo "creds candidates:"
  printf "  - %s (exists: %s)\n" \
    "$dir/.credentials.json"               "$( [[ -f \"$dir/.credentials.json\" ]] && echo yes || echo no )" \
    "$dir/.claude/.credentials.json"       "$( [[ -f \"$dir/.claude/.credentials.json\" ]] && echo yes || echo no )" \
    "$HOME/.claude/.credentials.json"      "$( [[ -f \"$HOME/.claude/.credentials.json\" ]] && echo yes || echo no )" \
    ${wr:+"$wr/.credentials.json"}         ${wr:+"$( [[ -f \"$wr/.credentials.json\" ]] && echo yes || echo no )"} \
    ${wr:+"$wr/.claude/.credentials.json"} ${wr:+"$( [[ -f \"$wr/.claude/.credentials.json\" ]] && echo yes || echo no )"}

  # 触发一次读取以确定 CREDS_PATH_FOUND
  read_credentials >/dev/null || true
  echo "creds chosen -> ${CREDS_PATH_FOUND:-<none>}"
  echo "============="
}



show_usage() {
  cat <<'USAGE'
Multi-Account Switcher for Claude Code
Usage: ccswitch.sh [--debug] COMMAND

Commands:
  --add-account                     Add current account to managed accounts
  --remove-account <num|email>      Remove account by number or email
  --list                            List all managed accounts
  --switch                          Rotate to next account in sequence
  --switch-to <num|email>           Switch to specific account number or email
  --doctor                          Print environment & path diagnostics
  --help                            Show this help message

Env:
  CLAUDE_CONFIG_DIR   Directory containing .claude.json and .credentials.json
  CCS_DEBUG           0(off)/1(debug logs)/2(debug+trace)

Notes for Cygwin:
  If your files are at /cygdrive/c/Users/<you>/.claude.json,
  the script will auto-detect them. You can also set:
    export CLAUDE_CONFIG_DIR="/cygdrive/c/Users/<you>"
USAGE
}

# ---------- Main ----------
main() {
  if [[ $EUID -eq 0 ]] && ! is_running_in_container; then die "Error: Do not run as root (unless in container)"; fi
  check_bash_version; check_dependencies
  case "${1:-}" in
    --add-account)        shift; cmd_add_account ;;
    --remove-account)     shift; cmd_remove_account "$@" ;;
    --list)               shift; cmd_list ;;
    --switch)             shift; cmd_switch ;;
    --switch-to)          shift; cmd_switch_to "$@" ;;
    --doctor)             shift; cmd_doctor ;;
    --help|"")            show_usage ;;
    *) die "Error: Unknown command '$1'" ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi
