# ==============================================================================
# AWS 3-Tier Architecture — Root Module
#
# Usage:
#   terraform workspace select dev      # or staging, prod
#   terraform init
#   terraform plan
#   terraform apply
#
# No -var-file needed. Workspace drives everything.
# ==============================================================================

data "aws_caller_identity" "current" {}

locals {
  name_prefix = "${var.project_name}-${terraform.workspace}"
}

# --- Latest Amazon Linux 2023 AMI ---
data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# ==============================================================================
# 1. VPC & Networking
# ==============================================================================

module "vpc" {
  source = "./modules/vpc"

  name_prefix        = local.name_prefix
  vpc_cidr           = var.vpc_cidr
  availability_zones = var.availability_zones

  public_subnet_cidrs   = var.public_subnet_cidrs
  private_subnet_cidrs  = var.private_subnet_cidrs
  database_subnet_cidrs = var.database_subnet_cidrs

  enable_flow_logs = local.env.enable_flow_logs
}

# ==============================================================================
# 2. Security Groups
# ==============================================================================

module "security_groups" {
  source = "./modules/security-groups"

  name_prefix       = local.name_prefix
  vpc_id            = module.vpc.vpc_id
  vpc_cidr          = var.vpc_cidr
  allowed_ssh_cidrs = local.env.allowed_ssh_cidrs
}

# ==============================================================================
# 3. Bastion Host
# ==============================================================================

module "bastion" {
  source = "./modules/bastion"

  name_prefix   = local.name_prefix
  ami_id        = data.aws_ami.amazon_linux.id
  instance_type = local.env.bastion_instance_type
  key_name      = var.key_name
  subnet_id     = module.vpc.public_subnet_ids[0]
  sg_id         = module.security_groups.bastion_sg_id
}

# ==============================================================================
# 4. Application Load Balancer
# ==============================================================================

module "alb" {
  source = "./modules/alb"

  name_prefix        = local.name_prefix
  vpc_id             = module.vpc.vpc_id
  public_subnet_ids  = module.vpc.public_subnet_ids
  security_group_id  = module.security_groups.alb_sg_id
  enable_access_logs = local.env.enable_alb_access_logs
}

# ==============================================================================
# 5. Auto Scaling Group (App Tier)
# ==============================================================================

module "asg" {
  source = "./modules/asg"

  name_prefix       = local.name_prefix
  ami_id            = data.aws_ami.amazon_linux.id
  instance_type     = local.env.instance_type
  key_name          = var.key_name
  security_group_id = module.security_groups.app_sg_id
  subnet_ids        = module.vpc.private_subnet_ids
  target_group_arn  = module.alb.target_group_arn

  min_size         = local.env.asg_min_size
  max_size         = local.env.asg_max_size
  desired_capacity = local.env.asg_desired_capacity

  scale_up_threshold   = var.scale_up_threshold
  scale_down_threshold = var.scale_down_threshold

  db_host     = module.rds.db_endpoint
  db_name     = var.db_name
  db_username = var.db_username
  db_password = var.db_password
}

# ==============================================================================
# 6. RDS MySQL (Data Tier)
# ==============================================================================

module "rds" {
  source = "./modules/rds"

  name_prefix       = local.name_prefix
  db_subnet_ids     = module.vpc.database_subnet_ids
  security_group_id = module.security_groups.db_sg_id

  instance_class   = local.env.db_instance_class
  db_name          = var.db_name
  db_username      = var.db_username
  db_password      = var.db_password
  multi_az         = local.env.db_multi_az
  backup_retention = local.env.db_backup_retention
}

# ==============================================================================
# 7. Route53 DNS (Optional — enabled in prod by default)
# ==============================================================================

module "route53" {
  source = "./modules/route53"
  count  = local.env.create_dns ? 1 : 0

  domain_name  = var.domain_name
  alb_dns_name = module.alb.alb_dns_name
  alb_zone_id  = module.alb.alb_zone_id
}
