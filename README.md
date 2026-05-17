# AWS 3-Tier Architecture with Terraform (IaC)

Production-grade Django web application deployment on AWS using a classic 3-tier architecture, fully managed as Infrastructure as Code with Terraform.

## Architecture

```
                    ┌─────────────┐
                    │   Route53   │
                    │  (DNS Zone) │
                    └──────┬──────┘
                           │
                    ┌──────▼──────┐
                    │     ALB     │
                    │(Public Sub) │
                    └──────┬──────┘
                           │
              ┌────────────┼────────────┐
              │            │            │
        ┌─────▼─────┐┌────▼────┐┌─────▼─────┐
        │  EC2 (AZ1) ││EC2 (AZ2)││ EC2 (AZ3) │
        │ Private Sub││Priv Sub ││ Priv Sub  │
        └─────┬──────┘└────┬────┘└─────┬─────┘
              │            │            │
              └────────────┼────────────┘
                           │
              ┌────────────┼────────────┐
              │                         │
        ┌─────▼─────┐           ┌──────▼──────┐
        │RDS Primary│           │ RDS Standby │
        │  (AZ1)    │◄─────────►│   (AZ2)     │
        │  DB Sub   │  Multi-AZ │   DB Sub    │
        └───────────┘           └─────────────┘
```

## Components

| Layer | Resources | Subnet |
|-------|-----------|--------|
| **Web/LB** | Application Load Balancer | Public |
| **App** | EC2 Auto Scaling Group (2-6 instances) | Private |
| **Data** | RDS MySQL 8.0 Multi-AZ | Database (Isolated) |
| **Mgmt** | Bastion Host | Public |

## Project Structure

```
.
├── terraform/
│   ├── modules/
│   │   ├── vpc/             # VPC, subnets, NAT GW, flow logs
│   │   ├── security-groups/ # All SG definitions
│   │   ├── alb/             # ALB, target group, listeners
│   │   ├── asg/             # Launch template, ASG, scaling policies
│   │   ├── rds/             # RDS MySQL Multi-AZ, subnet group
│   │   ├── route53/         # DNS zone and records
│   │   └── bastion/         # Bastion host for SSH access
│   ├── environments/
│   │   ├── dev/
│   │   ├── staging/
│   │   └── prod/
│   ├── backend/             # S3 + DynamoDB state backend
│   ├── main.tf
│   ├── variables.tf
│   ├── outputs.tf
│   ├── providers.tf
│   └── terraform.tfvars.example
├── django-app/              # Sample Django application
├── scripts/                 # Deployment & bootstrap scripts
├── .github/workflows/       # CI/CD pipeline
└── docs/
```

## Prerequisites

- Terraform >= 1.6
- AWS CLI v2 configured with appropriate credentials
- An AWS account with permissions for VPC, EC2, RDS, ALB, Route53, S3, DynamoDB, CloudWatch
- A registered domain (for Route53) — optional
- SSH key pair created in target AWS region

## Quick Start

### 1. Provision State Backend

```bash
cd terraform/backend
terraform init
terraform apply
```

### 2. Deploy Infrastructure

```bash
cd terraform/

# Initialize with remote backend
terraform init \
  -backend-config="bucket=your-tfstate-bucket" \
  -backend-config="key=env/dev/terraform.tfstate" \
  -backend-config="region=us-east-1" \
  -backend-config="dynamodb_table=terraform-locks"

# Select workspace
terraform workspace select dev || terraform workspace new dev

# Review plan
terraform plan -var-file="environments/dev/terraform.tfvars"

# Apply
terraform apply -var-file="environments/dev/terraform.tfvars"
```

### 3. Deploy Django App

The Django app is deployed via EC2 user data during instance launch. To update:

```bash
# SSH via bastion
ssh -J ec2-user@<bastion-ip> ec2-user@<private-ip>

# Or use the deployment script
./scripts/deploy-app.sh
```

## Environment Management

Uses `terraform workspace` for environment isolation:

```bash
terraform workspace new staging
terraform workspace new prod
terraform workspace select prod
terraform plan -var-file="environments/prod/terraform.tfvars"
```

## Key Features

- **High Availability**: Multi-AZ deployment across 3 availability zones
- **Auto Scaling**: CPU-based scaling at 70% threshold (2 min, 6 max instances)
- **Security**: Private subnets for app/db, bastion host, least-privilege SGs
- **Disaster Recovery**: RDS Multi-AZ failover, automated backups (7-day retention)
- **Monitoring**: CloudWatch alarms, VPC flow logs, ALB access logs
- **IaC Best Practices**: Modular Terraform, remote state with locking, workspace-based environments
- **CI/CD**: GitHub Actions pipeline with `terraform plan` before every `apply`

## Estimated AWS Cost (dev)

| Resource | Approximate Monthly Cost |
|----------|------------------------|
| NAT Gateway | ~$32 |
| ALB | ~$16 |
| EC2 (2x t3.micro) | ~$15 |
| RDS (db.t3.micro) | ~$25 |
| Bastion (t3.nano) | ~$4 |
| **Total** | **~$92/mo** |

> Use `terraform destroy` when not in use to avoid charges.

## License

MIT
