#!/bin/bash
#
# docker-cleanup.sh - Comprehensive Docker resource cleanup
#
# Features:
#   - Removes stopped containers, dangling images, unused volumes/networks
#   - Clears build cache (including buildx)
#   - Age-based filtering (--older-than)
#   - Dry-run mode for safe preview
#   - Space reclamation reporting
#
# Usage:
#   ./cleanup.sh [OPTIONS]
#
# Options:
#   -a, --all           Remove ALL unused images, not just dangling
#   -v, --volumes       Also prune unused volumes (destructive!)
#   -b, --buildx        Also prune buildx cache
#   -o, --older-than    Only remove resources older than duration (e.g., 24h, 7d)
#   -d, --dry-run       Preview what would be removed without deleting
#   -f, --force         Skip confirmation prompts
#   -h, --help          Show this help message
#
# Examples:
#   ./cleanup.sh --dry-run                    # Preview cleanup
#   ./cleanup.sh --all --volumes              # Full cleanup including volumes
#   ./cleanup.sh --older-than 7d --force      # Remove resources older than 7 days
#   ./cleanup.sh -a -b -f                     # Full cleanup with buildx cache
#
# Author: ghndrx
# License: MIT

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color
BOLD='\033[1m'

# Default options
ALL_IMAGES=false
PRUNE_VOLUMES=false
PRUNE_BUILDX=false
OLDER_THAN=""
DRY_RUN=false
FORCE=false

# Logging functions
log_info() { echo -e "${BLUE}ℹ${NC} $1"; }
log_success() { echo -e "${GREEN}✓${NC} $1"; }
log_warning() { echo -e "${YELLOW}⚠${NC} $1"; }
log_error() { echo -e "${RED}✗${NC} $1" >&2; }
log_header() { echo -e "\n${BOLD}${CYAN}═══ $1 ═══${NC}\n"; }

# Print usage
usage() {
    sed -n '3,26p' "$0" | sed 's/^# //' | sed 's/^#//'
    exit 0
}

# Parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -a|--all)
                ALL_IMAGES=true
                shift
                ;;
            -v|--volumes)
                PRUNE_VOLUMES=true
                shift
                ;;
            -b|--buildx)
                PRUNE_BUILDX=true
                shift
                ;;
            -o|--older-than)
                OLDER_THAN="$2"
                shift 2
                ;;
            -d|--dry-run)
                DRY_RUN=true
                shift
                ;;
            -f|--force)
                FORCE=true
                shift
                ;;
            -h|--help)
                usage
                ;;
            *)
                log_error "Unknown option: $1"
                usage
                ;;
        esac
    done
}

# Check if Docker is available
check_docker() {
    if ! command -v docker &> /dev/null; then
        log_error "Docker is not installed or not in PATH"
        exit 1
    fi
    
    if ! docker info &> /dev/null; then
        log_error "Docker daemon is not running or you don't have permission"
        exit 1
    fi
}

# Get disk usage before cleanup
get_disk_usage() {
    docker system df 2>/dev/null || echo "Unable to get disk usage"
}

# Format bytes to human readable
format_bytes() {
    local bytes=$1
    if [[ $bytes -ge 1073741824 ]]; then
        echo "$(awk "BEGIN {printf \"%.2f\", $bytes/1073741824}")GB"
    elif [[ $bytes -ge 1048576 ]]; then
        echo "$(awk "BEGIN {printf \"%.2f\", $bytes/1048576}")MB"
    elif [[ $bytes -ge 1024 ]]; then
        echo "$(awk "BEGIN {printf \"%.2f\", $bytes/1024}")KB"
    else
        echo "${bytes}B"
    fi
}

# Get reclaimable space estimate
get_reclaimable_space() {
    docker system df --format '{{.Reclaimable}}' 2>/dev/null | head -1 || echo "unknown"
}

# Build filter arguments for age-based cleanup
build_filter_args() {
    local filter_args=""
    if [[ -n "$OLDER_THAN" ]]; then
        filter_args="--filter until=$OLDER_THAN"
    fi
    echo "$filter_args"
}

# Cleanup stopped containers
cleanup_containers() {
    log_header "Cleaning Stopped Containers"
    
    local filter_args
    filter_args=$(build_filter_args)
    
    local stopped_count
    stopped_count=$(docker ps -aq --filter "status=exited" 2>/dev/null | wc -l)
    
    if [[ $stopped_count -eq 0 ]]; then
        log_info "No stopped containers to remove"
        return
    fi
    
    log_info "Found $stopped_count stopped container(s)"
    
    if $DRY_RUN; then
        log_warning "[DRY RUN] Would remove these containers:"
        docker ps -a --filter "status=exited" --format "  - {{.Names}} ({{.Image}}, stopped {{.Status}})"
    else
        # shellcheck disable=SC2086
        docker container prune -f $filter_args
        log_success "Removed stopped containers"
    fi
}

# Cleanup images
cleanup_images() {
    log_header "Cleaning Docker Images"
    
    local filter_args
    filter_args=$(build_filter_args)
    
    local all_flag=""
    if $ALL_IMAGES; then
        all_flag="-a"
        log_info "Removing ALL unused images (not just dangling)"
    else
        log_info "Removing dangling images only (use --all for unused images)"
    fi
    
    local dangling_count
    dangling_count=$(docker images -f "dangling=true" -q 2>/dev/null | wc -l)
    
    if [[ $dangling_count -eq 0 ]] && ! $ALL_IMAGES; then
        log_info "No dangling images to remove"
        return
    fi
    
    if $DRY_RUN; then
        log_warning "[DRY RUN] Would remove these images:"
        if $ALL_IMAGES; then
            docker images --format "  - {{.Repository}}:{{.Tag}} ({{.Size}}, {{.CreatedSince}})" | head -20
        else
            docker images -f "dangling=true" --format "  - {{.ID}} ({{.Size}}, {{.CreatedSince}})"
        fi
    else
        # shellcheck disable=SC2086
        docker image prune -f $all_flag $filter_args
        log_success "Removed unused images"
    fi
}

# Cleanup volumes
cleanup_volumes() {
    log_header "Cleaning Docker Volumes"
    
    if ! $PRUNE_VOLUMES; then
        log_info "Volume cleanup skipped (use --volumes to enable)"
        return
    fi
    
    log_warning "Volume cleanup is DESTRUCTIVE - data will be lost!"
    
    local volume_count
    volume_count=$(docker volume ls -qf "dangling=true" 2>/dev/null | wc -l)
    
    if [[ $volume_count -eq 0 ]]; then
        log_info "No unused volumes to remove"
        return
    fi
    
    log_info "Found $volume_count unused volume(s)"
    
    if $DRY_RUN; then
        log_warning "[DRY RUN] Would remove these volumes:"
        docker volume ls -f "dangling=true" --format "  - {{.Name}} ({{.Driver}})"
    else
        docker volume prune -f
        log_success "Removed unused volumes"
    fi
}

# Cleanup networks
cleanup_networks() {
    log_header "Cleaning Docker Networks"
    
    local network_count
    # Count non-default networks that aren't in use
    network_count=$(docker network ls --filter "type=custom" -q 2>/dev/null | wc -l)
    
    if [[ $network_count -eq 0 ]]; then
        log_info "No unused custom networks to remove"
        return
    fi
    
    if $DRY_RUN; then
        log_warning "[DRY RUN] Would prune unused networks"
        docker network ls --filter "type=custom" --format "  - {{.Name}} ({{.Driver}})"
    else
        docker network prune -f
        log_success "Removed unused networks"
    fi
}

# Cleanup build cache
cleanup_build_cache() {
    log_header "Cleaning Build Cache"
    
    local filter_args
    filter_args=$(build_filter_args)
    
    if $DRY_RUN; then
        log_warning "[DRY RUN] Would clear build cache"
        docker buildx du 2>/dev/null || docker builder du 2>/dev/null || log_info "Unable to show build cache size"
    else
        # shellcheck disable=SC2086
        docker builder prune -f $filter_args
        log_success "Removed build cache"
    fi
}

# Cleanup buildx cache (multi-platform builder)
cleanup_buildx_cache() {
    log_header "Cleaning Buildx Cache"
    
    if ! $PRUNE_BUILDX; then
        log_info "Buildx cleanup skipped (use --buildx to enable)"
        return
    fi
    
    if ! docker buildx version &> /dev/null; then
        log_info "Buildx not available, skipping"
        return
    fi
    
    local filter_args
    filter_args=$(build_filter_args)
    
    if $DRY_RUN; then
        log_warning "[DRY RUN] Would clear buildx cache"
        docker buildx du 2>/dev/null || log_info "Unable to show buildx cache size"
    else
        # shellcheck disable=SC2086
        docker buildx prune -f $filter_args
        log_success "Removed buildx cache"
    fi
}

# Confirmation prompt
confirm_cleanup() {
    if $FORCE || $DRY_RUN; then
        return 0
    fi
    
    echo -e "\n${YELLOW}This will clean up Docker resources.${NC}"
    echo "Options selected:"
    echo "  - All images: $ALL_IMAGES"
    echo "  - Volumes: $PRUNE_VOLUMES"
    echo "  - Buildx cache: $PRUNE_BUILDX"
    [[ -n "$OLDER_THAN" ]] && echo "  - Older than: $OLDER_THAN"
    echo
    
    read -rp "Continue? [y/N] " response
    case "$response" in
        [yY][eE][sS]|[yY])
            return 0
            ;;
        *)
            log_info "Cleanup cancelled"
            exit 0
            ;;
    esac
}

# Main cleanup routine
main() {
    parse_args "$@"
    check_docker
    
    echo -e "${BOLD}${CYAN}"
    echo "╔═══════════════════════════════════════╗"
    echo "║       Docker Cleanup Utility          ║"
    echo "╚═══════════════════════════════════════╝"
    echo -e "${NC}"
    
    $DRY_RUN && log_warning "DRY RUN MODE - No changes will be made"
    
    log_header "Current Docker Disk Usage"
    get_disk_usage
    
    confirm_cleanup
    
    cleanup_containers
    cleanup_images
    cleanup_volumes
    cleanup_networks
    cleanup_build_cache
    cleanup_buildx_cache
    
    log_header "Final Docker Disk Usage"
    get_disk_usage
    
    echo
    if $DRY_RUN; then
        log_warning "DRY RUN complete - run without --dry-run to apply changes"
    else
        log_success "Docker cleanup complete!"
    fi
}

main "$@"
