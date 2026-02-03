#!/usr/bin/env bash
#
# assume-role.sh - AWS role assumption with MFA support and session caching
#
# Features:
#   - MFA token prompting
#   - Session caching (avoids re-auth within session duration)
#   - Cross-account support with external-id
#   - Environment variable export or eval-friendly output
#   - AWS CLI profile-aware
#
# Usage:
#   source assume-role.sh <role-arn> [options]
#   eval "$(assume-role.sh <role-arn> [options])"
#
# Options:
#   -m, --mfa-serial <arn>     MFA device ARN (auto-detected if not specified)
#   -e, --external-id <id>     External ID for cross-account roles
#   -d, --duration <seconds>   Session duration (default: 3600, max: 43200)
#   -s, --session-name <name>  Session name (default: assumed-role-session)
#   -p, --profile <profile>    AWS CLI profile for source credentials
#   -r, --region <region>      AWS region
#   -c, --no-cache             Disable session caching
#   -v, --verbose              Verbose output
#   -h, --help                 Show this help

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Defaults
DURATION=3600
SESSION_NAME="assumed-role-session-$$"
CACHE_DIR="${HOME}/.aws/cli/cache"
USE_CACHE=true
VERBOSE=false

# Log functions
log_info() { [[ "$VERBOSE" == "true" ]] && echo -e "${BLUE}[INFO]${NC} $*" >&2 || true; }
log_success() { echo -e "${GREEN}[OK]${NC} $*" >&2; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*" >&2; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

usage() {
    grep '^#' "$0" | grep -v '#!/' | cut -c 3-
    exit 0
}

# Parse arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -m|--mfa-serial) MFA_SERIAL="$2"; shift 2 ;;
            -e|--external-id) EXTERNAL_ID="$2"; shift 2 ;;
            -d|--duration) DURATION="$2"; shift 2 ;;
            -s|--session-name) SESSION_NAME="$2"; shift 2 ;;
            -p|--profile) AWS_PROFILE="$2"; shift 2 ;;
            -r|--region) AWS_REGION="$2"; shift 2 ;;
            -c|--no-cache) USE_CACHE=false; shift ;;
            -v|--verbose) VERBOSE=true; shift ;;
            -h|--help) usage ;;
            -*) log_error "Unknown option: $1"; exit 1 ;;
            *) 
                if [[ -z "${ROLE_ARN:-}" ]]; then
                    ROLE_ARN="$1"
                else
                    log_error "Unexpected argument: $1"
                    exit 1
                fi
                shift
                ;;
        esac
    done

    if [[ -z "${ROLE_ARN:-}" ]]; then
        log_error "Role ARN is required"
        echo "Usage: assume-role.sh <role-arn> [options]" >&2
        exit 1
    fi
}

# Generate cache key based on role and MFA
get_cache_key() {
    local key="${ROLE_ARN}:${MFA_SERIAL:-none}:${EXTERNAL_ID:-none}"
    echo "$key" | sha256sum | cut -c1-16
}

# Check for valid cached credentials
get_cached_credentials() {
    [[ "$USE_CACHE" != "true" ]] && return 1
    
    local cache_key
    cache_key=$(get_cache_key)
    local cache_file="${CACHE_DIR}/assume-role-${cache_key}.json"
    
    if [[ -f "$cache_file" ]]; then
        local expiration
        expiration=$(jq -r '.Credentials.Expiration' "$cache_file" 2>/dev/null || echo "")
        
        if [[ -n "$expiration" ]]; then
            local exp_epoch now_epoch
            exp_epoch=$(date -d "$expiration" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%S" "${expiration%+*}" +%s 2>/dev/null || echo 0)
            now_epoch=$(date +%s)
            
            # Use cached creds if more than 5 minutes remain
            if (( exp_epoch - now_epoch > 300 )); then
                log_info "Using cached credentials (expires: $expiration)"
                cat "$cache_file"
                return 0
            fi
        fi
    fi
    
    return 1
}

# Save credentials to cache
save_cached_credentials() {
    [[ "$USE_CACHE" != "true" ]] && return 0
    
    local credentials="$1"
    local cache_key
    cache_key=$(get_cache_key)
    
    mkdir -p "$CACHE_DIR"
    chmod 700 "$CACHE_DIR"
    
    local cache_file="${CACHE_DIR}/assume-role-${cache_key}.json"
    echo "$credentials" > "$cache_file"
    chmod 600 "$cache_file"
    
    log_info "Credentials cached to $cache_file"
}

# Auto-detect MFA device
detect_mfa_device() {
    if [[ -n "${MFA_SERIAL:-}" ]]; then
        return 0
    fi
    
    log_info "Detecting MFA device..."
    
    local profile_args=()
    [[ -n "${AWS_PROFILE:-}" ]] && profile_args+=(--profile "$AWS_PROFILE")
    
    local mfa_devices
    mfa_devices=$(aws iam list-mfa-devices "${profile_args[@]}" --query 'MFADevices[0].SerialNumber' --output text 2>/dev/null || echo "None")
    
    if [[ "$mfa_devices" != "None" && -n "$mfa_devices" ]]; then
        MFA_SERIAL="$mfa_devices"
        log_info "Detected MFA device: $MFA_SERIAL"
    fi
}

# Prompt for MFA token
get_mfa_token() {
    local token
    echo -n "Enter MFA code for ${MFA_SERIAL}: " >&2
    read -r token
    echo "$token"
}

# Assume the role
assume_role() {
    local profile_args=()
    local assume_args=()
    
    [[ -n "${AWS_PROFILE:-}" ]] && profile_args+=(--profile "$AWS_PROFILE")
    [[ -n "${AWS_REGION:-}" ]] && profile_args+=(--region "$AWS_REGION")
    
    assume_args+=(--role-arn "$ROLE_ARN")
    assume_args+=(--role-session-name "$SESSION_NAME")
    assume_args+=(--duration-seconds "$DURATION")
    
    if [[ -n "${EXTERNAL_ID:-}" ]]; then
        assume_args+=(--external-id "$EXTERNAL_ID")
    fi
    
    if [[ -n "${MFA_SERIAL:-}" ]]; then
        local mfa_token
        mfa_token=$(get_mfa_token)
        assume_args+=(--serial-number "$MFA_SERIAL")
        assume_args+=(--token-code "$mfa_token")
    fi
    
    log_info "Assuming role: $ROLE_ARN"
    
    local result
    if ! result=$(aws sts assume-role "${profile_args[@]}" "${assume_args[@]}" --output json 2>&1); then
        log_error "Failed to assume role: $result"
        exit 1
    fi
    
    echo "$result"
}

# Export credentials as environment variables
export_credentials() {
    local credentials="$1"
    
    local access_key secret_key session_token expiration
    access_key=$(echo "$credentials" | jq -r '.Credentials.AccessKeyId')
    secret_key=$(echo "$credentials" | jq -r '.Credentials.SecretAccessKey')
    session_token=$(echo "$credentials" | jq -r '.Credentials.SessionToken')
    expiration=$(echo "$credentials" | jq -r '.Credentials.Expiration')
    
    # Output for eval or sourcing
    cat <<EOF
export AWS_ACCESS_KEY_ID='${access_key}'
export AWS_SECRET_ACCESS_KEY='${secret_key}'
export AWS_SESSION_TOKEN='${session_token}'
export AWS_CREDENTIAL_EXPIRATION='${expiration}'
unset AWS_PROFILE
EOF
    
    log_success "Role assumed: $ROLE_ARN"
    log_info "Session expires: $expiration"
}

# Main
main() {
    parse_args "$@"
    
    # Check for required tools
    command -v aws >/dev/null 2>&1 || { log_error "AWS CLI not found"; exit 1; }
    command -v jq >/dev/null 2>&1 || { log_error "jq not found"; exit 1; }
    
    # Try cache first
    local credentials
    if credentials=$(get_cached_credentials); then
        export_credentials "$credentials"
        return 0
    fi
    
    # Detect MFA if needed
    detect_mfa_device
    
    # Assume role
    credentials=$(assume_role)
    
    # Cache for future use
    save_cached_credentials "$credentials"
    
    # Export
    export_credentials "$credentials"
}

main "$@"
