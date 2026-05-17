# ==============================================================================
# Environment Configuration — driven by terraform.workspace
#
# Usage:
#   terraform workspace new dev       (first time)
#   terraform workspace select dev    (subsequent)
#   terraform plan                    (no -var-file needed)
#   terraform apply
#
# All environment-specific values live here. Switch workspace = switch env.
# ==============================================================================

locals {
  # --------------------------------------------------------------------------
  # Per-environment settings
  # --------------------------------------------------------------------------
  env_config = {
    dev = {
      instance_type         = "t3.micro"
      asg_min_size          = 1
      asg_max_size          = 2
      asg_desired_capacity  = 1
      db_instance_class     = "db.t3.micro"
      db_multi_az           = false
      db_backup_retention   = 1
      bastion_instance_type = "t3.micro"
      enable_flow_logs      = false
      enable_alb_access_logs = false
      create_dns            = false
      allowed_ssh_cidrs     = ["0.0.0.0/0"]
    }

    staging = {
      instance_type         = "t3.small"
      asg_min_size          = 2
      asg_max_size          = 4
      asg_desired_capacity  = 2
      db_instance_class     = "db.t3.small"
      db_multi_az           = true
      db_backup_retention   = 3
      bastion_instance_type = "t3.micro"
      enable_flow_logs      = true
      enable_alb_access_logs = false
      create_dns            = false
      allowed_ssh_cidrs     = ["0.0.0.0/0"]
    }

    prod = {
      instance_type         = "t3.medium"
      asg_min_size          = 2
      asg_max_size          = 6
      asg_desired_capacity  = 2
      db_instance_class     = "db.r5.large"
      db_multi_az           = true
      db_backup_retention   = 7
      bastion_instance_type = "t3.micro"
      enable_flow_logs      = true
      enable_alb_access_logs = true
      create_dns            = true
      allowed_ssh_cidrs     = ["0.0.0.0/0"]  # CHANGE THIS to your office IP
    }
  }

  # --------------------------------------------------------------------------
  # Resolve current environment — falls back to dev if workspace not mapped
  # --------------------------------------------------------------------------
  env = lookup(local.env_config, terraform.workspace, local.env_config["dev"])
}
