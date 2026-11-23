# -----------------------------------------------------------------------------
# outputs.tf
# Useful information displayed after "terraform apply".
# VPN pre-shared keys are intentionally NOT output; retrieve the full tunnel
# configuration from the AWS console (VPC > Site-to-Site VPN > Download
# configuration) so secrets do not end up in terminal history or CI logs.
# -----------------------------------------------------------------------------

output "region" {
  description = "AWS region the environment was deployed to."
  value       = var.aws_region
}

output "vpc_id" {
  description = "ID of the VPC."
  value       = aws_vpc.main.id
}

output "external_subnet_id" {
  description = "ID of the external (public) subnet."
  value       = aws_subnet.external.id
}

output "internal_subnet_id" {
  description = "ID of the internal (private) subnet."
  value       = aws_subnet.internal.id
}

output "servers" {
  description = "Hostname, role, instance ID, subnet tier, and private IP of every server."
  value = {
    for key, instance in aws_instance.server : key => {
      hostname    = local.servers[key].hostname
      role        = local.servers[key].role
      instance_id = instance.id
      subnet      = contains(tolist(local.external_servers), key) ? "external" : "internal"
      private_ip  = instance.private_ip
    }
  }
}

output "external_public_ips" {
  description = "Elastic IP addresses of the two external Linux servers."
  value       = { for key, eip in aws_eip.external : local.servers[key].hostname => eip.public_ip }
}

output "domain_controller_ips" {
  description = "Private IPs of the domain controllers. Use these as DNS servers for domain-joined clients."
  value       = [aws_instance.server["dc1"].private_ip, aws_instance.server["dc2"].private_ip]
}

output "radius_server_ip" {
  description = "Private IP of the NPS server. Configure school switches and wireless controllers to use it as their RADIUS server."
  value       = aws_instance.server["nps"].private_ip
}

output "vpn_connection_id" {
  description = "ID of the site-to-site VPN connection."
  value       = aws_vpn_connection.school.id
}

output "vpn_tunnel_endpoints" {
  description = "AWS public endpoints for the two IPsec tunnels. Configure both on the school firewall."
  value = {
    tunnel1 = aws_vpn_connection.school.tunnel1_address
    tunnel2 = aws_vpn_connection.school.tunnel2_address
  }
}

output "nat_gateway_public_ip" {
  description = "Public IP used by internal servers for outbound traffic (null if NAT is disabled)."
  value       = var.enable_nat_gateway ? aws_eip.nat[0].public_ip : null
}

output "flow_log_group" {
  description = "CloudWatch Logs group that receives VPC Flow Logs."
  value       = aws_cloudwatch_log_group.flow_logs.name
}
