#!/usr/bin/env bash

set -e

# =============================================================================
# INTERACTIVE JFROG PLATFORM SWITCH SCRIPT
# =============================================================================
# This script provides an interactive way to switch JFrog Platform Deployments
# and update all BookVerse repositories with new configuration
# =============================================================================

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Logging functions
log_info() { echo -e "${BLUE}ℹ️  $1${NC}"; }
log_success() { echo -e "${GREEN}✅ $1${NC}"; }
log_warning() { echo -e "${YELLOW}⚠️  $1${NC}"; }
log_error() { echo -e "${RED}❌ $1${NC}"; }
log_prompt() { echo -e "${CYAN}🔹 $1${NC}"; }

# =============================================================================
# INTERACTIVE INPUT FUNCTIONS
# =============================================================================

prompt_for_jpd_host() {
    echo ""
    log_prompt "Enter the new JFrog Platform host URL:"
    log_info "Format: https://yourcompany.jfrog.io"
    log_info "Example: https://acme.jfrog.io"
    echo ""
    read -p "JFrog Platform Host URL: " jpd_host
    
    # Remove trailing slash if present
    jpd_host=$(echo "$jpd_host" | sed 's:/*$::')
    
    if [[ -z "$jpd_host" ]]; then
        log_error "Host URL is required"
        exit 1
    fi
    
    echo "$jpd_host"
}

prompt_for_admin_token() {
    echo ""
    log_prompt "Enter the admin token for the new JFrog Platform:"
    log_warning "This token will be used to validate connectivity and update repositories"
    echo ""
    read -s -p "Admin Token: " admin_token
    echo "" # New line after hidden input
    
    if [[ -z "$admin_token" ]]; then
        log_error "Admin token is required"
        exit 1
    fi
    
    echo "$admin_token"
}

confirm_switch() {
    local jpd_host="$1"
    local current_host="${JFROG_URL:-https://apptrustswampupc.jfrog.io}"
    
    echo ""
    echo "🔄 JFrog Platform Switch Confirmation"
    echo "===================================="
    echo ""
    echo "Current Platform: $current_host"
    echo "New Platform:     $jpd_host"
    echo ""
    log_warning "This will update secrets and variables in ALL BookVerse repositories!"
    echo ""
    log_prompt "Type 'SWITCH' to confirm platform migration:"
    read -p "Confirmation: " confirmation
    
    if [[ "$confirmation" != "SWITCH" ]]; then
        log_error "Platform switch cancelled"
        exit 1
    fi
    
    log_success "Platform switch confirmed"
}

# =============================================================================
# VALIDATION FUNCTIONS
# =============================================================================

validate_prerequisites() {
    log_info "Checking prerequisites..."
    
    # Check if gh CLI is installed and authenticated
    if ! command -v gh &> /dev/null; then
        log_error "GitHub CLI (gh) is not installed"
        log_info "Install it from: https://cli.github.com/"
        exit 1
    fi
    
    # Check if authenticated
    if ! gh auth status &> /dev/null; then
        log_error "GitHub CLI is not authenticated"
        log_info "Run: gh auth login"
        exit 1
    fi
    
    # Check if curl and jq are available
    if ! command -v curl &> /dev/null; then
        log_error "curl is not installed"
        exit 1
    fi
    
    if ! command -v jq &> /dev/null; then
        log_error "jq is not installed" 
        exit 1
    fi
    
    log_success "All prerequisites satisfied"
}

validate_host_format() {
    local host="$1"
    
    log_info "Validating host format..."
    
    # Check format
    if [[ ! "$host" =~ ^https://[a-zA-Z0-9.-]+\.jfrog\.io$ ]]; then
        log_error "Invalid host format"
        log_error "Expected: https://host.jfrog.io"
        log_error "Received: $host"
        exit 1
    fi
    
    log_success "Host format is valid"
}

test_connectivity_and_auth() {
    local host="$1"
    local token="$2"
    
    log_info "Testing connectivity and authentication..."
    
    # Test basic connectivity
    if ! curl -s --fail --max-time 10 "$host" > /dev/null; then
        log_error "Cannot reach JFrog platform: $host"
        exit 1
    fi
    
    # Test authentication
    local response
    response=$(curl -s --max-time 10 \
        --header "Authorization: Bearer $token" \
        --write-out "%{http_code}" \
        "$host/artifactory/api/system/ping" 2>/dev/null || echo "000")
    
    local http_code="${response: -3}"
    
    if [[ "$http_code" != "200" ]]; then
        log_error "Authentication failed (HTTP $http_code)"
        if [[ "$http_code" == "000" ]]; then
            log_error "Connection failed - check host URL and network connectivity"
        elif [[ "$http_code" == "401" ]]; then
            log_error "Invalid admin token"
        elif [[ "$http_code" == "403" ]]; then
            log_error "Token lacks required permissions"
        fi
        exit 1
    fi
    
    log_success "Connectivity and authentication verified"
}

test_services() {
    local host="$1"
    local token="$2"
    
    log_info "Testing platform services..."
    
    # Test Artifactory
    if curl -s --fail --max-time 10 \
        --header "Authorization: Bearer $token" \
        "$host/artifactory/api/system/ping" > /dev/null; then
        log_success "Artifactory service: Available"
    else
        log_error "Artifactory service: Not available"
        exit 1
    fi
    
    # Test Access (optional)
    if curl -s --fail --max-time 10 \
        --header "Authorization: Bearer $token" \
        "$host/access/api/v1/system/ping" > /dev/null 2>&1; then
        log_success "Access service: Available"
    else
        log_warning "Access service: Not available (may be expected)"
    fi
}

# =============================================================================
# REPOSITORY ENVIRONMENTS MAPPING (Artifactory)
# =============================================================================

patch_repo_envs() {
    local jpd_host="$1"
    local admin_token="$2"
    local repo_key="$3"
    shift 3
    local -a envs=("$@")

    # Build JSON array for environments
    local env_json
    env_json=$(printf '"%s",' "${envs[@]}")
    env_json="[${env_json%,}]"

    local body
    body=$(mktemp)
    local code
    code=$(curl -sS -L -o "$body" -w "%{http_code}" -X PATCH \
        "$jpd_host/artifactory/api/v2/repositories/$repo_key" \
        -H "Authorization: Bearer $admin_token" \
        -H "Content-Type: application/json" \
        -d "{\"environments\": $env_json}" || echo 000)

    if [[ "$code" -ge 200 && "$code" -lt 300 ]]; then
        log_success "  → $repo_key environments set to $env_json"
    else
        log_warning "  → Failed to patch $repo_key environments (HTTP $code)"
        cat "$body" 2>/dev/null || true
    fi
    rm -f "$body"
}

repair_repository_environments() {
    local jpd_host="$1"
    local admin_token="$2"

    log_info "Repairing repository environments mapping (internal → DEV/QA/STAGING, release → PROD)"

    # Project key (allow override via env, default to bookverse)
    local project_key="${PROJECT_KEY:-bookverse}"

    # Internal repos map to project-prefixed DEV/QA/STAGING
    local dev_envs=("${project_key}-DEV" "${project_key}-QA" "${project_key}-STAGING")

    # Fetch all repositories and filter by project prefix
    local list_json
    list_json=$(curl -sS -L -H "Authorization: Bearer $admin_token" \
        "$jpd_host/artifactory/api/repositories" 2>/dev/null || echo "[]")

    # Extract keys belonging to this project
    mapfile -t repo_keys < <(echo "$list_json" | jq -r --arg p "${project_key}-" '.[]? | select(.key | startswith($p)) | .key')

    for key in "${repo_keys[@]}"; do
        if [[ "$key" == *"-internal-local" ]]; then
            patch_repo_envs "$jpd_host" "$admin_token" "$key" "${dev_envs[@]}"
        elif [[ "$key" == *"-release-local" ]]; then
            patch_repo_envs "$jpd_host" "$admin_token" "$key" "PROD"
        fi
    done

    log_success "Repository environments mapping repaired."
}

# =============================================================================
# REPOSITORY UPDATE FUNCTIONS
# =============================================================================

get_bookverse_repos() {
    # Get GitHub organization (defaults to current user)
    local github_org
    github_org=$(gh api user --jq .login)
    
    # List of BookVerse repositories
    local repos=(
        "bookverse-inventory"
        "bookverse-recommendations" 
        "bookverse-checkout"
        "bookverse-platform"
        "bookverse-web"
        "bookverse-helm"
        "bookverse-demo-assets"
        "bookverse-demo-init"
    )
    
    # Check which repos actually exist
    local existing_repos=()
    for repo in "${repos[@]}"; do
        if gh repo view "$github_org/$repo" > /dev/null 2>&1; then
            existing_repos+=("$github_org/$repo")
        else
            log_warning "Repository $github_org/$repo not found - skipping"
        fi
    done
    
    printf '%s\n' "${existing_repos[@]}"
}

update_repository() {
    local full_repo="$1"
    local jpd_host="$2"
    local admin_token="$3"
    
    log_info "Updating $full_repo..."
    
    # Extract docker registry from URL
    local docker_registry
    docker_registry=$(echo "$jpd_host" | sed 's|https://||')
    
    local success=true
    
    # Update secrets (suppress errors for repos that don't have these)
    echo "$admin_token" | gh secret set JFROG_ADMIN_TOKEN --repo "$full_repo" 2>/dev/null || true
    echo "$admin_token" | gh secret set JFROG_ACCESS_TOKEN --repo "$full_repo" 2>/dev/null || true
    
    # Update variables
    if ! gh variable set JFROG_URL --body "$jpd_host" --repo "$full_repo" 2>/dev/null; then
        log_warning "  → Could not update JFROG_URL variable"
        success=false
    fi
    
    if ! gh variable set DOCKER_REGISTRY --body "$docker_registry" --repo "$full_repo" 2>/dev/null; then
        log_warning "  → Could not update DOCKER_REGISTRY variable"
        success=false
    fi
    
    if [[ "$success" == true ]]; then
        log_success "  → $full_repo updated successfully"
    else
        log_warning "  → $full_repo partially updated"
    fi
    
    # Optional: open a PR to replace hardcoded old hostnames in repo files
    # Detect default branch
    local default_branch
    default_branch=$(gh repo view "$full_repo" --json defaultBranchRef --jq .defaultBranchRef.name 2>/dev/null || echo "main")

    # Create a working dir
    local workdir
    workdir=$(mktemp -d)
    pushd "$workdir" >/dev/null

    if gh repo clone "$full_repo" repo >/dev/null 2>&1; then
        cd repo
        git checkout -b chore/switch-platform-$(date +%Y%m%d%H%M%S) >/dev/null 2>&1 || true

        # Compute new registry (host without scheme)
        local new_registry
        new_registry=$(echo "$jpd_host" | sed 's|https://||')

        # Replace common occurrences in tracked files
        # Replace evidencetrial.jfrog.io with new host
        if rg -l "evidencetrial\.jfrog\.io" >/dev/null 2>&1; then
            rg -l "evidencetrial\\.jfrog\\.io" | xargs sed -i '' -e "s|evidencetrial\\.jfrog\\.io|${new_registry}|g"
        fi

        # Replace https://evidencetrial.jfrog.io with new URL
        if rg -l "https://evidencetrial\.jfrog\.io" >/dev/null 2>&1; then
            rg -l "https://evidencetrial\\.jfrog\\.io" | xargs sed -i '' -e "s|https://evidencetrial\\.jfrog\\.io|${jpd_host}|g"
        fi

        # Commit if changes
        if ! git diff --quiet; then
            git add -A
            git commit -m "chore: switch platform host to ${new_registry}" >/dev/null 2>&1 || true
            git push -u origin HEAD >/dev/null 2>&1 || true
            # Open PR
            gh pr create --title "chore: switch platform host to ${new_registry}" \
              --body "Automated replacement of old host with ${jpd_host}." \
              --base "$default_branch" >/dev/null 2>&1 || true
            log_success "  → Opened PR with host replacements in $full_repo"
        else
            log_info "  → No host replacements needed in $full_repo"
        fi
    else
        log_warning "  → Could not clone $full_repo for in-repo replacements"
    fi

    popd >/dev/null || true
    rm -rf "$workdir"

    return 0
}

update_all_repositories() {
    local jpd_host="$1"
    local admin_token="$2"
    
    log_info "Discovering BookVerse repositories..."
    
    local repos
    mapfile -t repos < <(get_bookverse_repos)
    
    if [[ ${#repos[@]} -eq 0 ]]; then
        log_error "No BookVerse repositories found"
        exit 1
    fi
    
    log_info "Found ${#repos[@]} repositories to update"
    echo ""
    
    local success_count=0
    for repo in "${repos[@]}"; do
        if update_repository "$repo" "$jpd_host" "$admin_token"; then
            ((success_count++))
        fi
    done
    
    echo ""
    log_success "Updated $success_count/${#repos[@]} repositories"
}

# =============================================================================
# MAIN EXECUTION
# =============================================================================

main() {
    echo "🔄 Interactive Platform Switch"
    echo "==================================="
    echo ""
    echo "This script will help you switch to a new JFrog Platform Deployment"
    echo "and update all BookVerse repositories with the new configuration."
    echo ""
    
    # Step 1: Check prerequisites
    validate_prerequisites
    echo ""
    
    # Step 2: Get JFrog platform host
    local jpd_host
    jpd_host=$(prompt_for_jpd_host)
    
    # Step 3: Validate host format
    validate_host_format "$jpd_host"
    echo ""
    
    # Step 4: Get admin token
    local admin_token
    admin_token=$(prompt_for_admin_token)
    echo ""
    
    # Step 5: Test connectivity and authentication
    test_connectivity_and_auth "$jpd_host" "$admin_token"
    echo ""
    
    # Step 6: Test services
    test_services "$jpd_host" "$admin_token"
    echo ""
    
    # Step 7: Get confirmation
    confirm_switch "$jpd_host"
    echo ""
    
    # Step 8: Update repositories
    update_all_repositories "$jpd_host" "$admin_token"
    echo ""

    # Step 9: Ensure repository environment mappings are correct
    repair_repository_environments "$jpd_host" "$admin_token"
    echo ""
    
    # Summary
    local docker_registry
    docker_registry=$(echo "$jpd_host" | sed 's|https://||')
    
    echo "🎯 Platform Switch Complete!"
    echo "================================="
    echo "New Configuration:"
    echo "  JFROG_URL: $jpd_host"
    echo "  DOCKER_REGISTRY: $docker_registry"
    echo ""
    echo "✅ All BookVerse repositories have been updated!"
    echo ""
    log_info "You can now run workflows on the new JFrog platform"
}

# Execute main function
main "$@"
