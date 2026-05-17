#!/usr/bin/env bash
# =============================================================================
# validate-infra.sh — Validate infrastructure health post-deploy
#
# Usage: ./scripts/validate-infra.sh
# =============================================================================
set -euo pipefail

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

PASS=0
FAIL=0
WARN=0

check_pass() { echo -e "  ${GREEN}✓${NC} $1"; PASS=$((PASS + 1)); }
check_fail() { echo -e "  ${RED}✗${NC} $1"; FAIL=$((FAIL + 1)); }
check_warn() { echo -e "  ${YELLOW}!${NC} $1"; WARN=$((WARN + 1)); }

echo "============================================"
echo "  Infrastructure Validation"
echo "============================================"
echo ""

# ---------------------------------------------------------------------------
# 1. Terraform state
# ---------------------------------------------------------------------------
echo "Terraform State:"
cd "$(dirname "$0")/../terraform"

if terraform validate -no-color &>/dev/null; then
    check_pass "Configuration is valid"
else
    check_fail "Configuration has errors"
fi

if terraform output -json &>/dev/null; then
    check_pass "State file is accessible"
else
    check_fail "State file is not accessible"
fi

# ---------------------------------------------------------------------------
# 2. ALB health
# ---------------------------------------------------------------------------
echo ""
echo "Application Load Balancer:"

ALB_DNS=$(terraform output -raw alb_dns_name 2>/dev/null || echo "")
if [[ -n "$ALB_DNS" ]]; then
    check_pass "ALB DNS resolved: ${ALB_DNS}"

    HTTP_CODE=$(curl -so /dev/null -w '%{http_code}' "http://${ALB_DNS}/health/" --connect-timeout 5 2>/dev/null || echo "000")
    if [[ "$HTTP_CODE" == "200" ]]; then
        check_pass "Health endpoint returns 200"
    elif [[ "$HTTP_CODE" == "000" ]]; then
        check_warn "Health endpoint unreachable (DNS may still be propagating)"
    else
        check_fail "Health endpoint returns ${HTTP_CODE}"
    fi
else
    check_fail "ALB DNS not found in Terraform outputs"
fi

# ---------------------------------------------------------------------------
# 3. ASG instances
# ---------------------------------------------------------------------------
echo ""
echo "Auto Scaling Group:"

ASG_NAME=$(terraform output -raw asg_name 2>/dev/null || echo "")
if [[ -n "$ASG_NAME" ]]; then
    DESIRED=$(aws autoscaling describe-auto-scaling-groups \
        --auto-scaling-group-names "$ASG_NAME" \
        --query 'AutoScalingGroups[0].DesiredCapacity' --output text 2>/dev/null || echo "?")
    HEALTHY=$(aws autoscaling describe-auto-scaling-groups \
        --auto-scaling-group-names "$ASG_NAME" \
        --query 'length(AutoScalingGroups[0].Instances[?HealthStatus==`Healthy`])' --output text 2>/dev/null || echo "?")

    if [[ "$DESIRED" == "$HEALTHY" && "$DESIRED" != "?" ]]; then
        check_pass "All ${DESIRED} instances healthy"
    elif [[ "$DESIRED" != "?" ]]; then
        check_warn "${HEALTHY}/${DESIRED} instances healthy"
    else
        check_fail "Could not query ASG status"
    fi
else
    check_fail "ASG name not found"
fi

# ---------------------------------------------------------------------------
# 4. RDS
# ---------------------------------------------------------------------------
echo ""
echo "RDS Database:"

RDS_ENDPOINT=$(terraform output -raw rds_endpoint 2>/dev/null || echo "")
if [[ -n "$RDS_ENDPOINT" ]]; then
    check_pass "RDS endpoint: ${RDS_ENDPOINT}"

    RDS_ID=$(echo "$RDS_ENDPOINT" | cut -d. -f1)
    RDS_STATUS=$(aws rds describe-db-instances \
        --db-instance-identifier "$RDS_ID" \
        --query 'DBInstances[0].DBInstanceStatus' --output text 2>/dev/null || echo "unknown")

    if [[ "$RDS_STATUS" == "available" ]]; then
        check_pass "RDS status: available"
    else
        check_warn "RDS status: ${RDS_STATUS}"
    fi

    MULTI_AZ=$(aws rds describe-db-instances \
        --db-instance-identifier "$RDS_ID" \
        --query 'DBInstances[0].MultiAZ' --output text 2>/dev/null || echo "unknown")
    if [[ "$MULTI_AZ" == "True" ]]; then
        check_pass "Multi-AZ: enabled"
    else
        check_warn "Multi-AZ: disabled"
    fi
else
    check_fail "RDS endpoint not found"
fi

# ---------------------------------------------------------------------------
# 5. Bastion
# ---------------------------------------------------------------------------
echo ""
echo "Bastion Host:"

BASTION_IP=$(terraform output -raw bastion_public_ip 2>/dev/null || echo "")
if [[ -n "$BASTION_IP" ]]; then
    check_pass "Bastion IP: ${BASTION_IP}"

    if nc -z -w 5 "$BASTION_IP" 22 2>/dev/null; then
        check_pass "SSH port reachable"
    else
        check_warn "SSH port not reachable (check your IP is in allowed_cidrs)"
    fi
else
    check_fail "Bastion IP not found"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "============================================"
echo -e "  Results: ${GREEN}${PASS} passed${NC}, ${RED}${FAIL} failed${NC}, ${YELLOW}${WARN} warnings${NC}"
echo "============================================"

[[ $FAIL -eq 0 ]] && exit 0 || exit 1
