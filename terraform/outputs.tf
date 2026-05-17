output "vpc_id" {
  description = "VPC ID"
  value       = module.vpc.vpc_id
}

output "alb_dns_name" {
  description = "ALB DNS name — access the application here"
  value       = module.alb.alb_dns_name
}

output "alb_url" {
  description = "Full URL to access the application"
  value       = "http://${module.alb.alb_dns_name}"
}

output "bastion_public_ip" {
  description = "Bastion host public IP for SSH access"
  value       = module.bastion.public_ip
}

output "rds_endpoint" {
  description = "RDS endpoint"
  value       = module.rds.db_endpoint
}

output "rds_port" {
  description = "RDS port"
  value       = module.rds.db_port
}

output "ssh_command" {
  description = "SSH command to connect through bastion"
  value       = "ssh -J ec2-user@${module.bastion.public_ip} ec2-user@<PRIVATE_IP>"
}

output "environment" {
  description = "Current workspace/environment"
  value       = terraform.workspace
}
