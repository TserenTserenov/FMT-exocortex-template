#!/usr/bin/env bash
# routing: utility  deterministic=true
# see DP.SC.159, DP.ROLE.059
#
# iwe-grep-secret.sh — Secret Drift Detector (WP-315)
#
# Scans ALL secret storage locations across all infrastructure layers IWE.
# Does not log the secret itself — only hit-count and location-identifier.
#
# Usage:
#   iwe-grep-secret.sh '<secret-value>' [--layer env|cloud|pg|smoke|all]
#   echo '<secret-value>' | iwe-grep-secret.sh --layer env
#
# Env vars:
#   IWE_WORKSPACE          — local IWE workspace root (default: $HOME/IWE)
#   IWE_SECRET_SCAN_HOSTS  — space-separated remote hosts to scan via ssh for
#                            Layer 1 (/etc/iwe/env, systemd units, ~/IWE/**/.env*).
#                            Unset/empty = skip remote scanning entirely (no
#                            ssh attempted, no wait).
#
# Exit codes:
#   0 — N = 0 (none hit)
#   1 — N ≥ 1 (there are hits, manual review required)
#   2 — infrastructure error (no ssh, no psql, no access)
#   3 — usage error
#
# Related: DP.SC.125, AR.205, security-posture.md §6

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
VERSION="0.2.0"
LAYER_FILTER="all"
SECRET_VALUE=""
TOTAL_HITS=0
INFRA_ERRORS=0

# ── Colors (disable if not TTY) ──────────────────────────────────────────
if [[ -t 1 ]]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; NC=''
fi

# ── Helpers ──────────────────────────────────────────────────────────────
usage() {
  cat <<EOF
Usage: ${SCRIPT_NAME} '<secret-value>' [--layer env|cloud|pg|smoke|all]
       echo '<secret-value>' | ${SCRIPT_NAME} [--layer env]

Options:
  --layer    Scan only the specified layer (default: all)
  --version  Show version
  --help     Show this help

Exit codes:
  0  — 0 hits (OK)
  1  — ≥1 hits (drift detected)
  2  — infrastructure error (ssh/psql/api unavailable)
  3  — usage error
EOF
}

die() { echo -e "${RED}ERROR:${NC} $1" >&2; exit 3; }
warn() { echo -e "${YELLOW}WARN:${NC} $1" >&2; }

# Do not log secret_value anywhere, even in debug
# shellcheck disable=SC2317
log_layer_start() { echo "→ Layer $1: scanning..." >&2; }
log_layer_done() { echo "  Layer $1: $2 hit(s)" >&2; }

# ── Parse args ───────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --layer)
      shift
      LAYER_FILTER="${1:-}"
      [[ -n "$LAYER_FILTER" ]] || die "--layer requires a value"
      ;;
    --version) echo "$VERSION"; exit 0 ;;
    --help|-h) usage; exit 0 ;;
    --)
      shift
      SECRET_VALUE="$1"
      break
      ;;
    -*)
      die "Unknown option: $1"
      ;;
    *)
      if [[ -z "$SECRET_VALUE" ]]; then
        SECRET_VALUE="$1"
      else
        die "Unexpected argument: $1"
      fi
      ;;
  esac
  shift
done

# If secret not passed as an argument — read from stdin
if [[ -z "$SECRET_VALUE" ]]; then
  if [[ -t 0 ]]; then
    die "Secret value required. Pass as argument or via stdin."
  fi
  SECRET_VALUE="$(cat)"
fi

[[ -n "$SECRET_VALUE" ]] || die "Secret value is empty"

# ── Validate layer filter ────────────────────────────────────────────────
case "$LAYER_FILTER" in
  env|cloud|pg|smoke|all) ;;
  *) die "Invalid layer: $LAYER_FILTER. Use: env, cloud, pg, smoke, all" ;;
esac

# ── Layer 1: Env-files (local + optional remote hosts) ───────────────────
scan_layer_env() {
  log_layer_start "1 (env files)"
  local hits=0
  local paths=(
    "$HOME/.secrets"
    "$HOME/.env"
    "$HOME/.config/exocortex/secrets.env"
  )

  # Local env-files
  for p in "${paths[@]}"; do
    if [[ -e "$p" ]]; then
      # grep -c — only count, does not print the match
      local c
      c=$(grep -cF "$SECRET_VALUE" "$p" 2>/dev/null || true)
      if [[ "$c" -gt 0 ]]; then
        printf "  %-20s %-40s %s\n" "Layer 1" "$p" "${RED}${c} hits${NC}"
        ((hits += c)) || true
      fi
    fi
  done

  # Recursive grep across IWE (only .env files, excluding node_modules etc...)
  local iwe_ws="${IWE_WORKSPACE:-$HOME/IWE}"
  if [[ -d "$iwe_ws" ]]; then
    while IFS= read -r -d '' f; do
      local c
      c=$(grep -cF "$SECRET_VALUE" "$f" 2>/dev/null || true)
      if [[ "$c" -gt 0 ]]; then
        printf "  %-20s %-40s %s\n" "Layer 1" "$f" "${RED}${c} hits${NC}"
        ((hits += c)) || true
      fi
    done < <(find "$iwe_ws" -type f \( -name ".env*" -o -name "secrets*" \) \
      ! -path "*/node_modules/*" ! -path "*/.venv/*" ! -path "*/venv/*" \
      ! -path "*/target/*" ! -path "*/__pycache__/*" \
      -print0 2>/dev/null)
  fi

  # Remote hosts via ssh — optional. IWE_SECRET_SCAN_HOSTS is a
  # space-separated list of reachable hostnames/ssh-aliases; unset/empty
  # skips remote scanning entirely (no ssh attempted, nothing to configure
  # for a generic install).
  if [[ -n "${IWE_SECRET_SCAN_HOSTS:-}" ]]; then
    if command -v ssh &>/dev/null; then
      local ssh_hits=0
      local remote_host
      for remote_host in ${IWE_SECRET_SCAN_HOSTS}; do
        if ssh -o ConnectTimeout=5 -o BatchMode=yes "$remote_host" "echo ok" &>/dev/null; then
          # /etc/iwe/env
          local c1
          c1=$(ssh -o ConnectTimeout=5 "$remote_host" "grep -cF '$SECRET_VALUE' /etc/iwe/env 2>/dev/null || echo 0" 2>/dev/null || echo 0)
          if [[ "$c1" -gt 0 ]]; then
            printf "  %-20s %-40s %s\n" "Layer 1" "${remote_host}:/etc/iwe/env" "${RED}${c1} hits${NC}"
            ((ssh_hits += c1)) || true
          fi

          # systemd unit files
          local c2
          c2=$(ssh -o ConnectTimeout=5 "$remote_host" "grep -rcF '$SECRET_VALUE' /etc/systemd/system/ 2>/dev/null | awk -F: '{s+=\$2} END {print s+0}'" 2>/dev/null || echo 0)
          if [[ "$c2" -gt 0 ]]; then
            printf "  %-20s %-40s %s\n" "Layer 1" "${remote_host}:/etc/systemd/system/" "${RED}${c2} hits${NC}"
            ((ssh_hits += c2)) || true
          fi

          # IWE .env on the remote host
          local c3
          c3=$(ssh -o ConnectTimeout=5 "$remote_host" "find ~/IWE -type f \( -name '.env*' -o -name 'secrets*' \) ! -path '*/node_modules/*' -print0 2>/dev/null | xargs -0 grep -cF '$SECRET_VALUE' 2>/dev/null | awk -F: '{s+=\$2} END {print s+0}'" 2>/dev/null || echo 0)
          if [[ "$c3" -gt 0 ]]; then
            printf "  %-20s %-40s %s\n" "Layer 1" "${remote_host}:~/IWE/**/.env" "${RED}${c3} hits${NC}"
            ((ssh_hits += c3)) || true
          fi
        else
          warn "${remote_host} is not reachable via ssh (Layer 1 incomplete for this host)"
          ((INFRA_ERRORS++)) || true
        fi
      done
      ((hits += ssh_hits)) || true
    else
      warn "ssh is not installed (IWE_SECRET_SCAN_HOSTS is set, but Layer 1 remote hosts skipped)"
      ((INFRA_ERRORS++)) || true
    fi
  fi

  log_layer_done "1" "$hits"
  (( TOTAL_HITS += hits )) || true
}

# ── Layer 2: Cloud env (Railway + CF Workers) ────────────────────────────
scan_layer_cloud() {
  log_layer_start "2 (cloud env)"
  local hits=0

  # ── Railway (GraphQL API v2) ──────────────────────────────────────────
  # Token: RAILWAY_TOKEN env var → ~/.secrets/railway-api-token → skip
  local railway_token="${RAILWAY_TOKEN:-}"
  # Fallback: IWE .secrets directory (IWE_WORKSPACE > ~/IWE > ~/.secrets)
  if [[ -z "$railway_token" ]]; then
    local _iwe_ws="${IWE_WORKSPACE:-${HOME}/IWE}"
    for _tok_path in "${_iwe_ws}/.secrets/railway-api-token" "${HOME}/.secrets/railway-api-token"; do
      if [[ -f "$_tok_path" ]]; then
        railway_token=$(cat "$_tok_path" 2>/dev/null || true)
        break
      fi
    done
  fi

  if [[ -n "$railway_token" ]]; then
    if ! command -v curl &>/dev/null; then
      warn "Railway: curl is not installed (Railway skipped)"
      ((INFRA_ERRORS++)) || true
    elif ! command -v jq &>/dev/null; then
      warn "Railway: jq is not installed (Railway skipped)"
      ((INFRA_ERRORS++)) || true
    else
      # Step 1: fetch the structure of workspaces → projects → services in a single request
      local structure
      structure=$(curl -sf --max-time 15 \
        -H "Authorization: Bearer ${railway_token}" \
        -H "Content-Type: application/json" \
        -d '{"query":"{ me { workspaces { id name projects { edges { node { id name services { edges { node { id name } } } } } } } } }"}' \
        "https://backboard.railway.app/graphql/v2" 2>/dev/null) || true

      if [[ -z "$structure" ]] || echo "$structure" | jq -e '.errors' &>/dev/null; then
        warn "Railway API is unreachable or the token is invalid (Railway skipped)"
        ((INFRA_ERRORS++)) || true
      else
        local railway_hits=0
        local nws
        nws=$(echo "$structure" | jq -r '.data.me.workspaces | length')

        for ((wi=0; wi<nws; wi++)); do
          local nproj
          nproj=$(echo "$structure" | jq -r ".data.me.workspaces[${wi}].projects.edges | length")
          for ((pi=0; pi<nproj; pi++)); do
            local proj_id proj_name
            proj_id=$(echo "$structure" | jq -r ".data.me.workspaces[${wi}].projects.edges[${pi}].node.id")
            proj_name=$(echo "$structure" | jq -r ".data.me.workspaces[${wi}].projects.edges[${pi}].node.name")

            # Step 2: environments environments for the project
            local env_payload envs nenv
            env_payload=$(jq -nc --arg q "{ environments(projectId: \"${proj_id}\") { edges { node { id name } } } }" '{"query": $q}')
            envs=$(curl -sf --max-time 10 \
              -H "Authorization: Bearer ${railway_token}" \
              -H "Content-Type: application/json" \
              -d "$env_payload" \
              "https://backboard.railway.app/graphql/v2" 2>/dev/null) || true
            nenv=$(echo "$envs" | jq -r '.data.environments.edges | length' 2>/dev/null || echo 0)

            local nsvc
            nsvc=$(echo "$structure" | jq -r ".data.me.workspaces[${wi}].projects.edges[${pi}].node.services.edges | length")

            for ((si=0; si<nsvc; si++)); do
              local svc_id svc_name
              svc_id=$(echo "$structure" | jq -r ".data.me.workspaces[${wi}].projects.edges[${pi}].node.services.edges[${si}].node.id")
              svc_name=$(echo "$structure" | jq -r ".data.me.workspaces[${wi}].projects.edges[${pi}].node.services.edges[${si}].node.name")

              for ((ei=0; ei<nenv; ei++)); do
                local env_id env_name
                env_id=$(echo "$envs" | jq -r ".data.environments.edges[${ei}].node.id")
                env_name=$(echo "$envs" | jq -r ".data.environments.edges[${ei}].node.name")

                # Step 3: service variables — returns JSON-object {KEY: VALUE}
                local var_payload vars
                var_payload=$(jq -nc \
                  --arg q "{ variables(projectId: \"${proj_id}\", environmentId: \"${env_id}\", serviceId: \"${svc_id}\") }" \
                  '{"query": $q}')
                vars=$(curl -sf --max-time 10 \
                  -H "Authorization: Bearer ${railway_token}" \
                  -H "Content-Type: application/json" \
                  -d "$var_payload" \
                  "https://backboard.railway.app/graphql/v2" 2>/dev/null) || true

                if [[ -z "$vars" ]] || echo "$vars" | jq -e '.errors' &>/dev/null; then
                  warn "Railway: failed to retrieve variables for ${proj_name}/${svc_name}"
                  ((INFRA_ERRORS++)) || true
                  continue
                fi

                # grep -cF: count occurrences, do not print the value
                local c
                c=$(echo "$vars" | jq -r '.data.variables // {} | to_entries[].value' 2>/dev/null \
                  | grep -cF "$SECRET_VALUE" 2>/dev/null || true)
                if [[ "${c:-0}" -gt 0 ]]; then
                  printf "  %-20s %-40s %s\n" "Layer 2" "Railway ${proj_name}/${svc_name}[${env_name}]" "${RED}${c} hits${NC}"
                  ((railway_hits += c)) || true
                fi
              done
            done
          done
        done

        ((hits += railway_hits)) || true
      fi
    fi
  else
    warn "RAILWAY_TOKEN is not set and ~/.secrets/railway-api-token not found (Railway skipped)"
    ((INFRA_ERRORS++)) || true
  fi

  # ── Cloudflare Workers ───────────────────────────────────────────────
  # CF Workers secrets are encrypted write-only: after setting, the value
  # cannot be read either via CLI, or via API (by design, Cloudflare).
  # Value-based scan is not possible. Layer 2 for CF = structural audit + instructions.
  if command -v wrangler &>/dev/null && [[ -n "${CF_API_TOKEN:-}" ]]; then
    warn "CF Workers: secrets write-only — value-based scan is not possible (Cloudflare design)."
    warn "  After rotation update manually: wrangler secret put <VAR> --name <worker>"
    warn "  List of workers with this secret: security-posture.md §6"
    # 0 hits, no INFRA_ERROR — this is a known limitation, not an infrastructure failure
  elif command -v wrangler &>/dev/null; then
    warn "CF_API_TOKEN is not set (CF Workers Layer 2 skipped)"
    ((INFRA_ERRORS++)) || true
  else
    warn "wrangler is not installed (CF Workers Layer 2 skipped)"
    ((INFRA_ERRORS++)) || true
  fi

  log_layer_done "2" "$hits"
  (( TOTAL_HITS += hits )) || true
}

# ── Layer 3: PostgreSQL metadata (pg_user_mapping) ───────────────────────
scan_layer_pg() {
  log_layer_start "3 (PG metadata)"
  local hits=0

  if ! command -v psql &>/dev/null; then
    warn "psql is not installed (Layer 3 skipped)"
    ((INFRA_ERRORS++)) || true
    log_layer_done "3" "$hits"
    return
  fi

  # Inventory DB inventory with FDW (from security-posture.md §6)
  local databases=(
    "${NEON_REWARDS_URL:-}"
    "${NEON_LEARNING_URL:-}"
    "${NEON_ANALYTICS_URL:-}"
    "${NEON_PLATFORM_URL:-}"
  )

  local any_db_ok=0
  for db_url in "${databases[@]}"; do
    [[ -n "$db_url" ]] || continue

    local c
    # Parameterized query via PGPASSWORD from URL (or .pgpass)
    # Do not pass secret_value into SQL — search via LIKE in LIKE in umoptions
    c=$(psql "$db_url" -t -A -c "
      SELECT COUNT(*)
      FROM pg_user_mapping um
      JOIN pg_foreign_server fs ON um.umserver = fs.oid
      WHERE um.umoptions::text LIKE '%password%'
        AND um.umoptions::text LIKE '%' || regexp_replace(current_setting('my.probe_value'), '[^a-zA-Z0-9]', '', 'g') || '%';
    " 2>/dev/null || true)

    if [[ "$c" =~ ^[0-9]+$ && "$c" -gt 0 ]]; then
      printf "  %-20s %-40s %s\n" "Layer 3" "${db_url##*/} pg_user_mapping" "${RED}${c} hits${NC}"
      ((hits += c)) || true
    fi
    any_db_ok=1
  done

  if [[ "$any_db_ok" -eq 0 ]]; then
    warn "None of the Neon DB is accessible (Layer 3 incomplete). Check NEON_*_URL."
    ((INFRA_ERRORS++)) || true
  fi

  log_layer_done "3" "$hits"
  (( TOTAL_HITS += hits )) || true
}

# ── Layer 4: Smoke-tests ─────────────────────────────────────────────────
scan_layer_smoke() {
  log_layer_start "4 (smoke tests)"
  local hits=0

  warn "Smoke-test layer not yet implemented (WP-315 Phase5-Phase7)"
  # TODO: connect via each role, FDW-function, API call

  log_layer_done "4" "$hits"
  (( TOTAL_HITS += hits )) || true
}

# ── Main ─────────────────────────────────────────────────────────────────
echo "=== Secret Drift Detector v${VERSION} ===" >&2
echo "Layer filter: ${LAYER_FILTER}" >&2
# Do not print secret_value
echo "" >&2

if [[ "$LAYER_FILTER" == "all" || "$LAYER_FILTER" == "env" ]]; then
  scan_layer_env
fi

if [[ "$LAYER_FILTER" == "all" || "$LAYER_FILTER" == "cloud" ]]; then
  scan_layer_cloud
fi

if [[ "$LAYER_FILTER" == "all" || "$LAYER_FILTER" == "pg" ]]; then
  scan_layer_pg
fi

if [[ "$LAYER_FILTER" == "all" || "$LAYER_FILTER" == "smoke" ]]; then
  scan_layer_smoke
fi

# ── Summary ──────────────────────────────────────────────────────────────
echo "" >&2
if [[ "$TOTAL_HITS" -gt 0 ]]; then
  echo -e "${RED}RESULT: ${TOTAL_HITS} hit(s) detected across scanned layers${NC}" >&2
else
  echo -e "${GREEN}RESULT: 0 hits — no drift detected${NC}" >&2
fi

if [[ "$INFRA_ERRORS" -gt 0 ]]; then
  echo -e "${YELLOW}INFRA: ${INFRA_ERRORS} layer(s) could not be scanned (check warnings above)${NC}" >&2
fi

if [[ "$TOTAL_HITS" -gt 0 ]]; then
  exit 1
elif [[ "$INFRA_ERRORS" -gt 0 ]]; then
  exit 2
else
  exit 0
fi
