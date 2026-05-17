#!/usr/bin/env bash
# =============================================================================
# deploy-app.sh — Deploy Django app to EC2 instances behind the ALB
#
# Usage:
#   ./scripts/deploy-app.sh [environment] [app-version]
#
# Examples:
#   ./scripts/deploy-app.sh dev latest
#   ./scripts/deploy-app.sh prod v1.2.3
#
# Prerequisites:
#   - AWS CLI configured with appropriate credentials
#   - Terraform outputs accessible (alb_dns, bastion_public_ip)
#   - SSH key for bastion host
# =============================================================================
set -euo pipefail

ENVIRONMENT="${1:-dev}"
APP_VERSION="${2:-latest}"
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DJANGO_APP_DIR="${PROJECT_ROOT}/django-app"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
DEPLOY_BUNDLE="django-app-${APP_VERSION}-${TIMESTAMP}.tar.gz"

# ---------------------------------------------------------------------------
# Color helpers
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()   { echo -e "${GREEN}[DEPLOY]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# ---------------------------------------------------------------------------
# Preflight checks
# ---------------------------------------------------------------------------
preflight() {
    log "Running preflight checks..."

    for cmd in aws tar ssh scp terraform; do
        if ! command -v "$cmd" &>/dev/null; then
            error "Required command not found: $cmd"
            exit 1
        fi
    done

    if [[ ! -d "$DJANGO_APP_DIR" ]]; then
        error "Django app directory not found: $DJANGO_APP_DIR"
        exit 1
    fi

    # Validate AWS credentials
    if ! aws sts get-caller-identity &>/dev/null; then
        error "AWS credentials not configured or expired"
        exit 1
    fi

    log "Preflight checks passed"
}

# ---------------------------------------------------------------------------
# Read Terraform outputs
# ---------------------------------------------------------------------------
get_terraform_outputs() {
    log "Reading Terraform outputs for environment: ${ENVIRONMENT}"

    cd "${PROJECT_ROOT}/terraform"

    BASTION_IP=$(terraform output -raw bastion_public_ip 2>/dev/null || true)
    ALB_DNS=$(terraform output -raw alb_dns_name 2>/dev/null || true)
    ASG_NAME=$(terraform output -raw asg_name 2>/dev/null || true)

    if [[ -z "$BASTION_IP" ]]; then
        error "Could not read bastion_public_ip from Terraform outputs"
        error "Make sure you have run: terraform apply"
        exit 1
    fi

    log "Bastion IP: ${BASTION_IP}"
    log "ALB DNS:    ${ALB_DNS}"
    log "ASG Name:   ${ASG_NAME}"
}

# ---------------------------------------------------------------------------
# Package the Django application
# ---------------------------------------------------------------------------
package_app() {
    log "Packaging Django application..."

    cd "$PROJECT_ROOT"
    tar czf "/tmp/${DEPLOY_BUNDLE}" \
        --exclude='__pycache__' \
        --exclude='*.pyc' \
        --exclude='.env' \
        --exclude='db.sqlite3' \
        --exclude='staticfiles' \
        -C django-app .

    local size
    size=$(du -h "/tmp/${DEPLOY_BUNDLE}" | cut -f1)
    log "Created bundle: ${DEPLOY_BUNDLE} (${size})"
}

# ---------------------------------------------------------------------------
# Discover running instances in the ASG
# ---------------------------------------------------------------------------
get_instance_ips() {
    log "Discovering instances in ASG..."

    INSTANCE_IDS=$(aws autoscaling describe-auto-scaling-groups \
        --auto-scaling-group-names "$ASG_NAME" \
        --query 'AutoScalingGroups[0].Instances[?LifecycleState==`InService`].InstanceId' \
        --output text 2>/dev/null || true)

    if [[ -z "$INSTANCE_IDS" ]]; then
        error "No InService instances found in ASG: ${ASG_NAME}"
        exit 1
    fi

    INSTANCE_IPS=$(aws ec2 describe-instances \
        --instance-ids $INSTANCE_IDS \
        --query 'Reservations[].Instances[].PrivateIpAddress' \
        --output text)

    local count
    count=$(echo "$INSTANCE_IPS" | wc -w)
    log "Found ${count} instance(s): ${INSTANCE_IPS}"
}

# ---------------------------------------------------------------------------
# Deploy to a single instance via bastion
# ---------------------------------------------------------------------------
deploy_to_instance() {
    local instance_ip="$1"
    local ssh_opts="-o StrictHostKeyChecking=no -o ConnectTimeout=10 -o ProxyJump=ec2-user@${BASTION_IP}"

    log "Deploying to ${instance_ip}..."

    # Upload bundle through bastion
    scp $ssh_opts "/tmp/${DEPLOY_BUNDLE}" "ec2-user@${instance_ip}:/tmp/${DEPLOY_BUNDLE}"

    # Execute deployment on the instance
    ssh $ssh_opts "ec2-user@${instance_ip}" bash -s <<REMOTE_SCRIPT
set -euo pipefail

echo "[REMOTE] Extracting application bundle..."
sudo mkdir -p /opt/django-app
sudo tar xzf "/tmp/${DEPLOY_BUNDLE}" -C /opt/django-app

echo "[REMOTE] Installing dependencies..."
cd /opt/django-app
sudo /opt/django-app/venv/bin/pip install -r requirements.txt --quiet 2>/dev/null || {
    echo "[REMOTE] Creating virtualenv..."
    python3.11 -m venv /opt/django-app/venv
    /opt/django-app/venv/bin/pip install -r requirements.txt --quiet
}

echo "[REMOTE] Running migrations..."
/opt/django-app/venv/bin/python manage.py migrate --noinput

echo "[REMOTE] Collecting static files..."
/opt/django-app/venv/bin/python manage.py collectstatic --noinput 2>/dev/null || true

echo "[REMOTE] Restarting Gunicorn..."
sudo systemctl restart gunicorn

echo "[REMOTE] Verifying health..."
sleep 3
if curl -sf http://localhost:8000/health/ > /dev/null; then
    echo "[REMOTE] Health check PASSED"
else
    echo "[REMOTE] Health check FAILED" >&2
    sudo journalctl -u gunicorn --no-pager -n 20
    exit 1
fi

# Cleanup
rm -f "/tmp/${DEPLOY_BUNDLE}"
echo "[REMOTE] Deployment complete on $(hostname)"
REMOTE_SCRIPT

    log "Instance ${instance_ip} deployed successfully"
}

# ---------------------------------------------------------------------------
# Rolling deployment across all instances
# ---------------------------------------------------------------------------
rolling_deploy() {
    local failed=0

    for ip in $INSTANCE_IPS; do
        log "--- Deploying to instance: ${ip} ---"

        if deploy_to_instance "$ip"; then
            log "Instance ${ip}: SUCCESS"
        else
            error "Instance ${ip}: FAILED"
            failed=$((failed + 1))
        fi

        # Brief pause between instances for rolling stability
        sleep 5
    done

    if [[ $failed -gt 0 ]]; then
        error "${failed} instance(s) failed deployment"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Post-deploy health verification via ALB
# ---------------------------------------------------------------------------
verify_deployment() {
    log "Verifying deployment via ALB..."

    local retries=5
    local wait_seconds=10

    for i in $(seq 1 $retries); do
        if curl -sf "http://${ALB_DNS}/health/" > /dev/null 2>&1; then
            log "ALB health check PASSED"
            return 0
        fi
        warn "Attempt ${i}/${retries} failed, waiting ${wait_seconds}s..."
        sleep $wait_seconds
    done

    error "ALB health check failed after ${retries} attempts"
    return 1
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    log "========================================="
    log "Deploying: ${ENVIRONMENT} / ${APP_VERSION}"
    log "Timestamp: ${TIMESTAMP}"
    log "========================================="

    preflight
    get_terraform_outputs
    package_app
    get_instance_ips
    rolling_deploy
    verify_deployment

    # Cleanup local bundle
    rm -f "/tmp/${DEPLOY_BUNDLE}"

    log "========================================="
    log "Deployment COMPLETE"
    log "Environment: ${ENVIRONMENT}"
    log "Version:     ${APP_VERSION}"
    log "ALB URL:     http://${ALB_DNS}"
    log "========================================="
}

main
