output "zone_id" {
  value = data.aws_route53_zone.main.zone_id
}

output "fqdn" {
  value = aws_route53_record.app.fqdn
}
