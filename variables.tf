# -----------------------------------------------------------------------------
# variables.tf
# Configurable values for the deployment. Defaults match the design document;
# values that are unique to the school (VPN peer IP, campus address range,
# key pair) have no default and must be set in terraform.tfvars.
# -----------------------------------------------------------------------------

# ---------------------------------------------------------------- General ----

variable "aws_region" {
  description = "AWS region to deploy into. us-east-2 (Ohio) is closest to Ann Arbor, MI."
  type        = string
  default     = "us-east-2"
}

variable "project_name" {
  description = "Short name used as a prefix for resource names and tags."
  type        = string
  default     = "charter-school"
}

variable "environment" {
  description = "Environment label applied as a tag (for example: prod, lab)."
  type        = string
  default     = "prod"
}

# ---------------------------------------------------------------- Network ----

variable "vpc_cidr" {
  description = "Address range for the VPC."
  type        = string
  default     = "10.20.0.0/16"
}

variable "external_subnet_cidr" {
  description = "Address range for the external (public) subnet."
  type        = string
  default     = "10.20.1.0/24"
}

variable "internal_subnet_cidr" {
  description = "Address range for the internal (private) subnet."
  type        = string
  default     = "10.20.2.0/24"
}

variable "availability_zone" {
  description = "Availability zone for both subnets. Leave empty to use the first AZ in the region."
  type        = string
  default     = ""
}

variable "enable_nat_gateway" {
  description = "Create a NAT Gateway so internal servers can download updates without accepting inbound internet traffic."
  type        = bool
  default     = true
}

# -------------------------------------------------------------------- VPN ----

variable "school_network_cidr" {
  description = "Private address range used at the school buildings. Must NOT overlap the VPC CIDR."
  type        = string

  validation {
    condition     = can(cidrhost(var.school_network_cidr, 0))
    error_message = "school_network_cidr must be a valid CIDR block, such as 10.10.0.0/16."
  }
}

variable "customer_gateway_ip" {
  description = "Public IPv4 address of the school's firewall/router that terminates the IPsec tunnel."
  type        = string

  validation {
    condition     = can(regex("^(\\d{1,3}\\.){3}\\d{1,3}$", var.customer_gateway_ip))
    error_message = "customer_gateway_ip must be an IPv4 address."
  }
}

variable "customer_gateway_bgp_asn" {
  description = "BGP ASN for the customer gateway. Required by AWS even when static routing is used."
  type        = number
  default     = 65000
}

variable "admin_cidr_blocks" {
  description = "Additional trusted source ranges allowed to use SSH/RDP. The school network is always allowed."
  type        = list(string)
  default     = []
}

# -------------------------------------------------------------- Compute ----

variable "key_pair_name" {
  description = "Name of an existing EC2 key pair. Used for Linux SSH and to decrypt Windows Administrator passwords."
  type        = string
}

variable "windows_instance_type" {
  description = "Instance type for Windows servers. c6i.xlarge = 4 vCPU / 8 GiB RAM."
  type        = string
  default     = "c6i.xlarge"
}

variable "linux_instance_type" {
  description = "Instance type for Linux servers. t3.medium = 2 vCPU / 4 GiB RAM."
  type        = string
  default     = "t3.medium"
}

variable "windows_ami_id" {
  description = "Optional Windows Server AMI ID. Leave empty to use the latest Windows Server 2022 Base AMI."
  type        = string
  default     = ""
}

variable "linux_ami_id" {
  description = "Optional Linux AMI ID. Leave empty to use the latest Ubuntu Server 24.04 LTS AMI."
  type        = string
  default     = ""
}

# -------------------------------------------------------------- Logging ----

variable "flow_log_retention_days" {
  description = "Number of days to keep VPC Flow Logs in CloudWatch Logs."
  type        = number
  default     = 30
}
