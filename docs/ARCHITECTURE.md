# Architecture Documentation

## Network Topology

```
┌─────────────────────────────────────────────────────────────────┐
│  VPC: 10.0.0.0/16                                               │
│                                                                  │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │  Public Subnets (10.0.1.0/24, 10.0.2.0/24, 10.0.3.0/24)│   │
│  │                                                           │   │
│  │  ┌─────────┐    ┌───────────────────────────────┐        │   │
│  │  │ Bastion │    │  Application Load Balancer     │        │   │
│  │  │  Host   │    │  (internet-facing, HTTP/HTTPS) │        │   │
│  │  └────┬────┘    └──────────────┬────────────────┘        │   │
│  └───────┼─────────────────────────┼────────────────────────┘   │
│          │ SSH (22)                │ HTTP (8000)                  │
│  ┌───────┼─────────────────────────┼────────────────────────┐   │
│  │  Private Subnets (10.0.11.0/24, 10.0.12.0/24, 10.0.13.0/24) │
│  │       │                         │                         │   │
│  │       ▼                         ▼                         │   │
│  │  ┌──────────────────────────────────────────────┐        │   │
│  │  │  Auto Scaling Group (min 1 / max 4)          │        │   │
│  │  │  ┌──────────┐  ┌──────────┐  ┌──────────┐   │        │   │
│  │  │  │  EC2     │  │  EC2     │  │  EC2     │   │        │   │
│  │  │  │ Gunicorn │  │ Gunicorn │  │ Gunicorn │   │        │   │
│  │  │  │ Django   │  │ Django   │  │ Django   │   │        │   │
│  │  │  └────┬─────┘  └────┬─────┘  └────┬─────┘   │        │   │
│  │  └───────┼──────────────┼──────────────┼────────┘        │   │
│  └──────────┼──────────────┼──────────────┼─────────────────┘   │
│             │ MySQL (3306) │              │                       │
│  ┌──────────┼──────────────┼──────────────┼─────────────────┐   │
│  │  DB Subnets (10.0.21.0/24, 10.0.22.0/24, 10.0.23.0/24) │   │
│  │          │              │              │                   │   │
│  │          ▼              ▼              ▼                   │   │
│  │  ┌──────────────────────────────────────────────┐        │   │
│  │  │  RDS MySQL 8.0 (Multi-AZ)                    │        │   │
│  │  │  Encrypted, Automated Backups, 7-day retain  │        │   │
│  │  └──────────────────────────────────────────────┘        │   │
│  └──────────────────────────────────────────────────────────┘   │
│                                                                  │
│  NAT Gateway (public subnet) ← Private subnet route             │
│  Internet Gateway ← Public subnet route                          │
└─────────────────────────────────────────────────────────────────┘
```

## Security Model

### Network Segmentation
- **Public subnets**: Only ALB and bastion host have public IPs
- **Private subnets**: Application servers — no direct internet ingress, NAT GW for outbound
- **DB subnets**: Database only — accessible only from app security group on port 3306

### Security Groups (Least Privilege)
| SG | Inbound | Source |
|----|---------|--------|
| ALB | 80, 443 | 0.0.0.0/0 |
| App | 8000 | ALB SG |
| App | 22 | Bastion SG |
| DB  | 3306 | App SG |
| Bastion | 22 | Allowed CIDRs |

### Additional Security
- IMDSv2 enforced on all EC2 instances (no Instance Metadata v1)
- EBS and RDS storage encrypted at rest
- VPC Flow Logs enabled (prod) for network audit
- S3 state bucket: versioned, KMS encrypted, public access blocked
- DynamoDB state lock prevents concurrent Terraform applies

## Scaling Behavior

**Auto Scaling Policies:**
- Scale up: +1 instance when average CPU > 70% for 2 consecutive 1-minute periods
- Scale down: -1 instance when average CPU < 30% for 3 consecutive 1-minute periods
- Cooldown: 300 seconds between scaling actions
- Instance refresh: rolling updates, 50% minimum healthy

**Health Checks:**
- ALB: HTTP GET `/health/` on port 8000, 5s interval, 3 healthy / 2 unhealthy thresholds
- ASG: ELB-based health check with 300s grace period

## Monitoring & Alarms

| Alarm | Metric | Threshold | Action |
|-------|--------|-----------|--------|
| High CPU | CPUUtilization | > 70% for 2 min | Scale up, SNS notify |
| Low CPU | CPUUtilization | < 30% for 3 min | Scale down |
| Unhealthy Hosts | UnHealthyHostCount | > 0 for 2 min | SNS notify |
| RDS CPU | CPUUtilization | > 80% for 5 min | SNS notify |
| RDS Storage | FreeStorageSpace | < 5 GB | SNS notify |
| RDS Connections | DatabaseConnections | > 80% max | SNS notify |

## Cost Estimates

### Dev (single instance, no Multi-AZ)
| Resource | Monthly Est. |
|----------|-------------|
| EC2 t3.micro (1x) | ~$8 |
| RDS db.t3.micro | ~$15 |
| NAT Gateway | ~$32 + data |
| ALB | ~$16 + data |
| **Total** | **~$75-90** |

### Prod (multi-instance, Multi-AZ)
| Resource | Monthly Est. |
|----------|-------------|
| EC2 t3.medium (2-6x) | ~$60-180 |
| RDS db.r5.large Multi-AZ | ~$350 |
| NAT Gateway | ~$32 + data |
| ALB | ~$16 + data |
| Route53 | ~$0.50 |
| CloudWatch | ~$10 |
| **Total** | **~$470-590** |

*Prices approximate, US East 1, on-demand. Reserved instances reduce 30-50%.*

## Deployment Pipeline

```
PR opened
  → terraform fmt -check
  → terraform validate
  → tfsec + checkov security scan
  → terraform plan (dev, staging, prod)
  → Plan output posted as PR comment

Merge to main
  → terraform apply (dev) — auto
  → post-deploy health check
  → terraform apply (staging) — manual approval
  → terraform apply (prod) — manual approval
```
