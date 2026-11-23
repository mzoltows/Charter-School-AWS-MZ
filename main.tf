# -----------------------------------------------------------------------------
# main.tf
# Charter school AWS environment:
#   - 1 VPC (10.20.0.0/16) in us-east-2
#   - External subnet (10.20.1.0/24) and internal subnet (10.20.2.0/24)
#   - Internet Gateway, optional NAT Gateway, public and private route tables
#   - IPsec site-to-site VPN to the school buildings (virtual private gateway)
#   - Role-based security groups
#   - 4 Windows servers (2 DCs, MSCA, NPS) in the internal subnet
#   - 4 Linux servers (2 external, 2 internal)
#   - VPC Flow Logs to CloudWatch Logs
# -----------------------------------------------------------------------------

data "aws_availability_zones" "available" {
  state = "available"
}

# Latest Windows Server 2022 Base AMI published by Amazon.
data "aws_ami" "windows" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["Windows_Server-2022-English-Full-Base-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# Latest Ubuntu Server 24.04 LTS AMI published by Canonical.
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

locals {
  name_prefix = "${var.project_name}-${var.environment}"
  az          = var.availability_zone != "" ? var.availability_zone : data.aws_availability_zones.available.names[0]

  windows_ami = var.windows_ami_id != "" ? var.windows_ami_id : data.aws_ami.windows.id
  linux_ami   = var.linux_ami_id != "" ? var.linux_ami_id : data.aws_ami.ubuntu.id

  # Sources that may reach internal services: the internal subnet itself and
  # the school buildings over the VPN. The external subnet is deliberately
  # excluded so a compromised public server cannot reach the domain.
  internal_sources = [var.internal_subnet_cidr, var.school_network_cidr]

  # Sources allowed to use SSH/RDP: the school network plus any extra ranges.
  admin_sources = distinct(concat([var.school_network_cidr], var.admin_cidr_blocks))

  # Ports used by Active Directory Domain Services and DNS.
  dc_ports = [
    { from = 53, to = 53, protocol = "tcp", description = "DNS" },
    { from = 53, to = 53, protocol = "udp", description = "DNS" },
    { from = 88, to = 88, protocol = "tcp", description = "Kerberos" },
    { from = 88, to = 88, protocol = "udp", description = "Kerberos" },
    { from = 123, to = 123, protocol = "udp", description = "NTP / Windows Time" },
    { from = 135, to = 135, protocol = "tcp", description = "RPC endpoint mapper" },
    { from = 389, to = 389, protocol = "tcp", description = "LDAP" },
    { from = 389, to = 389, protocol = "udp", description = "LDAP / CLDAP" },
    { from = 445, to = 445, protocol = "tcp", description = "SMB (SYSVOL, Group Policy)" },
    { from = 464, to = 464, protocol = "tcp", description = "Kerberos password change" },
    { from = 464, to = 464, protocol = "udp", description = "Kerberos password change" },
    { from = 636, to = 636, protocol = "tcp", description = "LDAPS" },
    { from = 3268, to = 3269, protocol = "tcp", description = "Global Catalog" },
    { from = 9389, to = 9389, protocol = "tcp", description = "AD Web Services" },
    { from = 49152, to = 65535, protocol = "tcp", description = "RPC dynamic ports" },
  ]

  # Ports used by Active Directory Certificate Services.
  ca_ports = [
    { from = 80, to = 80, protocol = "tcp", description = "CRL / AIA download" },
    { from = 135, to = 135, protocol = "tcp", description = "RPC endpoint mapper (enrollment)" },
    { from = 443, to = 443, protocol = "tcp", description = "Web enrollment" },
    { from = 49152, to = 65535, protocol = "tcp", description = "RPC dynamic ports (enrollment)" },
  ]

  # Server inventory. Static private IPs make DNS and RADIUS client
  # configuration predictable for the network team.
  servers = {
    dc1 = {
      hostname   = "SCH-DC01"
      role       = "Primary Domain Controller (AD DS, DNS)"
      os         = "windows"
      subnet_id  = aws_subnet.internal.id
      private_ip = cidrhost(var.internal_subnet_cidr, 10)
      sg_ids     = [aws_security_group.domain_controllers.id, aws_security_group.windows_admin.id]
      software   = "AD-Domain-Services,DNS"
    }
    dc2 = {
      hostname   = "SCH-DC02"
      role       = "Secondary Domain Controller (AD DS, DNS)"
      os         = "windows"
      subnet_id  = aws_subnet.internal.id
      private_ip = cidrhost(var.internal_subnet_cidr, 11)
      sg_ids     = [aws_security_group.domain_controllers.id, aws_security_group.windows_admin.id]
      software   = "AD-Domain-Services,DNS"
    }
    ca = {
      hostname   = "SCH-CA01"
      role       = "Microsoft Certificate Authority (AD CS)"
      os         = "windows"
      subnet_id  = aws_subnet.internal.id
      private_ip = cidrhost(var.internal_subnet_cidr, 20)
      sg_ids     = [aws_security_group.certificate_authority.id, aws_security_group.windows_admin.id]
      software   = "ADCS-Cert-Authority,ADCS-Web-Enrollment"
    }
    nps = {
      hostname   = "SCH-NPS01"
      role       = "Network Policy Server (RADIUS)"
      os         = "windows"
      subnet_id  = aws_subnet.internal.id
      private_ip = cidrhost(var.internal_subnet_cidr, 30)
      sg_ids     = [aws_security_group.nps.id, aws_security_group.windows_admin.id]
      software   = "NPAS"
    }
    web = {
      hostname   = "sch-web01"
      role       = "External Web Server"
      os         = "linux"
      subnet_id  = aws_subnet.external.id
      private_ip = cidrhost(var.external_subnet_cidr, 10)
      sg_ids     = [aws_security_group.external_web.id]
      software   = "nginx"
    }
    app = {
      hostname   = "sch-app01"
      role       = "External Application Server"
      os         = "linux"
      subnet_id  = aws_subnet.external.id
      private_ip = cidrhost(var.external_subnet_cidr, 11)
      sg_ids     = [aws_security_group.external_app.id]
      software   = "nginx"
    }
    mgmt = {
      hostname   = "sch-mgmt01"
      role       = "Internal Management Server"
      os         = "linux"
      subnet_id  = aws_subnet.internal.id
      private_ip = cidrhost(var.internal_subnet_cidr, 40)
      sg_ids     = [aws_security_group.management.id]
      software   = "ansible git"
    }
    mon = {
      hostname   = "sch-mon01"
      role       = "Internal Monitoring and Logging Server"
      os         = "linux"
      subnet_id  = aws_subnet.internal.id
      private_ip = cidrhost(var.internal_subnet_cidr, 50)
      sg_ids     = [aws_security_group.monitoring.id]
      software   = "rsyslog"
    }
  }

  external_servers = toset(["web", "app"])
}

# =============================================================================
# Network
# =============================================================================

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${local.name_prefix}-vpc" }
}

resource "aws_subnet" "external" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.external_subnet_cidr
  availability_zone       = local.az
  map_public_ip_on_launch = false # Public IPs are assigned explicitly with Elastic IPs.

  tags = { Name = "${local.name_prefix}-external-subnet", Tier = "external" }
}

resource "aws_subnet" "internal" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.internal_subnet_cidr
  availability_zone       = local.az
  map_public_ip_on_launch = false

  tags = { Name = "${local.name_prefix}-internal-subnet", Tier = "internal" }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = { Name = "${local.name_prefix}-igw" }
}

# Optional NAT Gateway: outbound-only internet access for the internal subnet.
resource "aws_eip" "nat" {
  count  = var.enable_nat_gateway ? 1 : 0
  domain = "vpc"

  tags       = { Name = "${local.name_prefix}-nat-eip" }
  depends_on = [aws_internet_gateway.main]
}

resource "aws_nat_gateway" "main" {
  count         = var.enable_nat_gateway ? 1 : 0
  allocation_id = aws_eip.nat[0].id
  subnet_id     = aws_subnet.external.id

  tags       = { Name = "${local.name_prefix}-nat" }
  depends_on = [aws_internet_gateway.main]
}

# Public route table: internet via the IGW, school network via the VPN.
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  tags = { Name = "${local.name_prefix}-public-rt" }
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.main.id
}

resource "aws_route" "public_to_school" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = var.school_network_cidr
  gateway_id             = aws_vpn_gateway.main.id
}

resource "aws_route_table_association" "external" {
  subnet_id      = aws_subnet.external.id
  route_table_id = aws_route_table.public.id
}

# Private route table: school network via the VPN, optional outbound via NAT.
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  tags = { Name = "${local.name_prefix}-private-rt" }
}

resource "aws_route" "private_to_school" {
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = var.school_network_cidr
  gateway_id             = aws_vpn_gateway.main.id
}

resource "aws_route" "private_nat" {
  count                  = var.enable_nat_gateway ? 1 : 0
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.main[0].id
}

resource "aws_route_table_association" "internal" {
  subnet_id      = aws_subnet.internal.id
  route_table_id = aws_route_table.private.id
}

# =============================================================================
# IPsec site-to-site VPN
# =============================================================================

resource "aws_vpn_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = { Name = "${local.name_prefix}-vgw" }
}

# Represents the firewall/router at the school buildings.
resource "aws_customer_gateway" "school" {
  bgp_asn    = var.customer_gateway_bgp_asn
  ip_address = var.customer_gateway_ip
  type       = "ipsec.1"

  tags = { Name = "${local.name_prefix}-school-cgw" }
}

resource "aws_vpn_connection" "school" {
  vpn_gateway_id      = aws_vpn_gateway.main.id
  customer_gateway_id = aws_customer_gateway.school.id
  type                = "ipsec.1"
  static_routes_only  = true

  # Restrict both tunnels to strong IKEv2 / AES-256 / SHA-256 settings.
  tunnel1_ike_versions                 = ["ikev2"]
  tunnel1_phase1_encryption_algorithms = ["AES256"]
  tunnel1_phase1_integrity_algorithms  = ["SHA2-256"]
  tunnel1_phase1_dh_group_numbers      = [14]
  tunnel1_phase2_encryption_algorithms = ["AES256"]
  tunnel1_phase2_integrity_algorithms  = ["SHA2-256"]
  tunnel1_phase2_dh_group_numbers      = [14]

  tunnel2_ike_versions                 = ["ikev2"]
  tunnel2_phase1_encryption_algorithms = ["AES256"]
  tunnel2_phase1_integrity_algorithms  = ["SHA2-256"]
  tunnel2_phase1_dh_group_numbers      = [14]
  tunnel2_phase2_encryption_algorithms = ["AES256"]
  tunnel2_phase2_integrity_algorithms  = ["SHA2-256"]
  tunnel2_phase2_dh_group_numbers      = [14]

  tags = { Name = "${local.name_prefix}-school-vpn" }
}

resource "aws_vpn_connection_route" "school" {
  vpn_connection_id      = aws_vpn_connection.school.id
  destination_cidr_block = var.school_network_cidr
}

# =============================================================================
# Security groups (least privilege, one per role)
# =============================================================================

# External web server: HTTP/HTTPS from anywhere, SSH only from admin sources.
resource "aws_security_group" "external_web" {
  name        = "${local.name_prefix}-external-web"
  description = "Public web server"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "SSH from trusted admin sources"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = local.admin_sources
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${local.name_prefix}-external-web-sg" }
}

# External application server: HTTPS from anywhere, SSH only from admin sources.
resource "aws_security_group" "external_app" {
  name        = "${local.name_prefix}-external-app"
  description = "Public application server"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "SSH from trusted admin sources"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = local.admin_sources
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${local.name_prefix}-external-app-sg" }
}

# Shared RDP access for all Windows servers, from admin sources only.
resource "aws_security_group" "windows_admin" {
  name        = "${local.name_prefix}-windows-admin"
  description = "RDP from trusted admin sources and the management server"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "RDP from trusted admin sources"
    from_port   = 3389
    to_port     = 3389
    protocol    = "tcp"
    cidr_blocks = local.admin_sources
  }

  ingress {
    description     = "RDP from management server"
    from_port       = 3389
    to_port         = 3389
    protocol        = "tcp"
    security_groups = [aws_security_group.management.id]
  }

  ingress {
    description     = "WinRM HTTPS from management server"
    from_port       = 5986
    to_port         = 5986
    protocol        = "tcp"
    security_groups = [aws_security_group.management.id]
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${local.name_prefix}-windows-admin-sg" }
}

# Domain controllers: AD/DNS ports from the internal subnet and school only.
resource "aws_security_group" "domain_controllers" {
  name        = "${local.name_prefix}-domain-controllers"
  description = "Active Directory Domain Services and DNS"
  vpc_id      = aws_vpc.main.id

  dynamic "ingress" {
    for_each = local.dc_ports
    content {
      description = ingress.value.description
      from_port   = ingress.value.from
      to_port     = ingress.value.to
      protocol    = ingress.value.protocol
      cidr_blocks = local.internal_sources
    }
  }

  # DC-to-DC replication uses many ports; allow all traffic between members
  # of this group only.
  ingress {
    description = "AD replication between domain controllers"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    self        = true
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${local.name_prefix}-domain-controllers-sg" }
}

# Certificate authority: enrollment and CRL ports from internal sources only.
resource "aws_security_group" "certificate_authority" {
  name        = "${local.name_prefix}-certificate-authority"
  description = "Active Directory Certificate Services"
  vpc_id      = aws_vpc.main.id

  dynamic "ingress" {
    for_each = local.ca_ports
    content {
      description = ingress.value.description
      from_port   = ingress.value.from
      to_port     = ingress.value.to
      protocol    = ingress.value.protocol
      cidr_blocks = local.internal_sources
    }
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${local.name_prefix}-certificate-authority-sg" }
}

# NPS: RADIUS from the school's network equipment (switches, wireless).
resource "aws_security_group" "nps" {
  name        = "${local.name_prefix}-nps"
  description = "Network Policy Server (RADIUS)"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "RADIUS authentication"
    from_port   = 1812
    to_port     = 1812
    protocol    = "udp"
    cidr_blocks = local.internal_sources
  }

  ingress {
    description = "RADIUS accounting"
    from_port   = 1813
    to_port     = 1813
    protocol    = "udp"
    cidr_blocks = local.internal_sources
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${local.name_prefix}-nps-sg" }
}

# Internal management server: SSH from admin sources only (via the VPN).
resource "aws_security_group" "management" {
  name        = "${local.name_prefix}-management"
  description = "Internal management server"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "SSH from trusted admin sources"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = local.admin_sources
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${local.name_prefix}-management-sg" }
}

# Internal monitoring server: receives syslog from every server in the VPC
# and from the school network; SSH and dashboard only from admin sources.
resource "aws_security_group" "monitoring" {
  name        = "${local.name_prefix}-monitoring"
  description = "Internal monitoring and centralized logging"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "Syslog (UDP) from VPC and school"
    from_port   = 514
    to_port     = 514
    protocol    = "udp"
    cidr_blocks = [var.vpc_cidr, var.school_network_cidr]
  }

  ingress {
    description = "Syslog (TCP) from VPC and school"
    from_port   = 514
    to_port     = 514
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr, var.school_network_cidr]
  }

  ingress {
    description = "Monitoring dashboard (HTTPS) from admin sources"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = local.admin_sources
  }

  ingress {
    description = "SSH from trusted admin sources"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = local.admin_sources
  }

  ingress {
    description     = "SSH from management server"
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.management.id]
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${local.name_prefix}-monitoring-sg" }
}

# =============================================================================
# EC2 instances
# =============================================================================

resource "aws_instance" "server" {
  for_each = local.servers

  ami                         = each.value.os == "windows" ? local.windows_ami : local.linux_ami
  instance_type               = each.value.os == "windows" ? var.windows_instance_type : var.linux_instance_type
  subnet_id                   = each.value.subnet_id
  private_ip                  = each.value.private_ip
  vpc_security_group_ids      = each.value.sg_ids
  key_name                    = var.key_pair_name
  associate_public_ip_address = false
  get_password_data           = each.value.os == "windows"

  # Require IMDSv2 to protect instance credentials.
  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  # Default root volume size, encrypted at rest.
  root_block_device {
    encrypted = true
  }

  # First-boot setup: set the hostname and install the role's base software.
  # Domain promotion, CA configuration, and NPS policies are completed by an
  # administrator afterward (see README.md, "Post-deployment configuration").
  user_data = each.value.os == "windows" ? join("\n", [
    "<powershell>",
    "Install-WindowsFeature -Name ${each.value.software} -IncludeManagementTools",
    "Rename-Computer -NewName '${each.value.hostname}' -Force -Restart",
    "</powershell>",
    ]) : join("\n", [
    "#!/bin/bash",
    "hostnamectl set-hostname ${each.value.hostname}",
    "apt-get update -y",
    "DEBIAN_FRONTEND=noninteractive apt-get upgrade -y",
    "DEBIAN_FRONTEND=noninteractive apt-get install -y ${each.value.software} unattended-upgrades",
  ])

  tags = {
    Name = each.value.hostname
    Role = each.value.role
    OS   = each.value.os
  }
}

# Static public IPs for the two external Linux servers only.
resource "aws_eip" "external" {
  for_each = local.external_servers

  domain   = "vpc"
  instance = aws_instance.server[each.key].id

  tags       = { Name = "${local.name_prefix}-${each.key}-eip" }
  depends_on = [aws_internet_gateway.main]
}

# =============================================================================
# VPC Flow Logs -> CloudWatch Logs
# =============================================================================

resource "aws_cloudwatch_log_group" "flow_logs" {
  name              = "/vpc/${local.name_prefix}/flow-logs"
  retention_in_days = var.flow_log_retention_days
}

data "aws_iam_policy_document" "flow_logs_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["vpc-flow-logs.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "flow_logs" {
  name               = "${local.name_prefix}-flow-logs-role"
  assume_role_policy = data.aws_iam_policy_document.flow_logs_assume.json
}

data "aws_iam_policy_document" "flow_logs_write" {
  statement {
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogGroups",
      "logs:DescribeLogStreams",
    ]
    resources = ["${aws_cloudwatch_log_group.flow_logs.arn}:*"]
  }
}

resource "aws_iam_role_policy" "flow_logs" {
  name   = "${local.name_prefix}-flow-logs-policy"
  role   = aws_iam_role.flow_logs.id
  policy = data.aws_iam_policy_document.flow_logs_write.json
}

resource "aws_flow_log" "vpc" {
  vpc_id          = aws_vpc.main.id
  traffic_type    = "ALL"
  iam_role_arn    = aws_iam_role.flow_logs.arn
  log_destination = aws_cloudwatch_log_group.flow_logs.arn

  tags = { Name = "${local.name_prefix}-flow-log" }
}
