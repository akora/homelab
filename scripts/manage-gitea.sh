#!/bin/bash
# Gitea Management Script
# Provides easy commands for Gitea deployment, backup, and restore operations

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOMELAB_DIR="$(dirname "$SCRIPT_DIR")"
PLAYBOOK_DIR="${HOMELAB_DIR}/ansible/playbooks"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging function
log() {
    echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

warn() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

# Usage function
usage() {
    cat << EOF
Gitea Management Script

Usage: $0 <command> [options]

Commands:
  deploy              Deploy Gitea with backup system
  backup              Create immediate backup
  restore [file]      Restore from backup (latest if no file specified)
  verify [file]       Verify backup integrity (latest if no file specified)
  status              Show Gitea status
  logs                Show Gitea logs
  list-backups        List available backups
  update              Update Gitea to latest version
  help                Show this help message

Examples:
  $0 deploy                                    # Deploy Gitea
  $0 backup                                    # Create backup now
  $0 restore                                   # Restore from latest backup
  $0 restore gitea-dump-20240121_020000.zip  # Restore specific backup
  $0 verify                                    # Verify latest backup
  $0 status                                    # Check Gitea status

EOF
    exit 1
}

# Check if running from correct directory
check_environment() {
    if [ ! -f "${PLAYBOOK_DIR}/gitea-with-backup.yml" ]; then
        error "Gitea playbook not found. Please run from homelab directory."
        exit 1
    fi
}

# Deploy Gitea
deploy_gitea() {
    log "Deploying Gitea with backup system..."
    cd "$HOMELAB_DIR"
    
    if ansible-playbook "${PLAYBOOK_DIR}/gitea-with-backup.yml" -i ansible/inventory/hosts; then
        log "Gitea deployment completed successfully!"
        info "Access Gitea at: https://git.l4n.io"
        info "Check deployment summary above for admin credentials"
    else
        error "Gitea deployment failed"
        exit 1
    fi
}

# Create backup
create_backup() {
    log "Creating Gitea backup..."
    if ssh rpi5-01 "sudo /opt/backups/gitea/scripts/gitea-backup.sh"; then
        log "Backup created successfully!"
    else
        error "Backup creation failed"
        exit 1
    fi
}

# Restore from backup
restore_backup() {
    local backup_file="${1:---latest}"
    
    warn "This will restore Gitea from backup and replace current data!"
    read -p "Are you sure you want to continue? (yes/no): " confirm
    if [ "$confirm" != "yes" ]; then
        info "Restore cancelled"
        exit 0
    fi
    
    log "Restoring Gitea from backup: $backup_file"
    if ssh rpi5-01 "sudo /opt/backups/gitea/scripts/gitea-restore.sh $backup_file"; then
        log "Restore completed successfully!"
        info "Please verify that all data has been restored correctly"
    else
        error "Restore failed"
        exit 1
    fi
}

# Verify backup
verify_backup() {
    local backup_file="${1:---latest}"
    
    log "Verifying backup: $backup_file"
    if ssh rpi5-01 "sudo /opt/backups/gitea/scripts/gitea-verify-backup.sh $backup_file"; then
        log "Backup verification completed!"
    else
        error "Backup verification failed"
        exit 1
    fi
}

# Show status
show_status() {
    log "Checking Gitea status..."
    ssh rpi5-01 "
        echo 'Container Status:'
        docker ps | grep gitea || echo 'Gitea container not running'
        echo ''
        echo 'Service Health:'
        curl -s -o /dev/null -w '%{http_code}' https://git.l4n.io/api/v1/version || echo 'Service not responding'
        echo ''
        echo 'Disk Usage:'
        du -sh /opt/docker/gitea /opt/backups/gitea 2>/dev/null || echo 'Directories not found'
    "
}

# Show logs
show_logs() {
    log "Showing Gitea logs (press Ctrl+C to exit)..."
    ssh rpi5-01 "docker logs gitea -f"
}

# List backups
list_backups() {
    log "Available Gitea backups:"
    ssh rpi5-01 "sudo /opt/backups/gitea/scripts/gitea-verify-backup.sh --list" || {
        warn "Could not list backups - backup system may not be deployed yet"
        exit 1
    }
}

# Update Gitea
update_gitea() {
    warn "This will update Gitea to the latest version"
    read -p "Are you sure you want to continue? (yes/no): " confirm
    if [ "$confirm" != "yes" ]; then
        info "Update cancelled"
        exit 0
    fi
    
    log "Creating pre-update backup..."
    create_backup
    
    log "Updating Gitea..."
    cd "$HOMELAB_DIR"
    if ansible-playbook "${PLAYBOOK_DIR}/gitea-with-backup.yml" -i ansible/inventory/hosts --tags upgrade; then
        log "Gitea update completed successfully!"
    else
        error "Gitea update failed"
        warn "You may need to restore from backup if there are issues"
        exit 1
    fi
}

# Main script logic
main() {
    check_environment
    
    if [ $# -eq 0 ]; then
        usage
    fi
    
    case "$1" in
        deploy)
            deploy_gitea
            ;;
        backup)
            create_backup
            ;;
        restore)
            restore_backup "${2:-}"
            ;;
        verify)
            verify_backup "${2:-}"
            ;;
        status)
            show_status
            ;;
        logs)
            show_logs
            ;;
        list-backups|list)
            list_backups
            ;;
        update)
            update_gitea
            ;;
        help|--help|-h)
            usage
            ;;
        *)
            error "Unknown command: $1"
            usage
            ;;
    esac
}

main "$@"
