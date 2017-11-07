##############################################################################
# Variables
##############################################################################
variable "azones" {
  type        = "list"
  description = "a list of availability zones to use"

  default = [
    "us-east-1c",
    "us-east-1d",
    "us-east-1e",
  ]
}

variable "environment" {
  type        = "string"
  description = "A name identifying a type of resource i.e., qa, staging, prod"
}

variable "name" {
  type        = "string"
  description = "name of the app or this vpc is for"
  default     = ""
}

variable "region" {
  type        = "string"
  default     = "us-east-1"
  description = "The region of AWS, for AMI lookups."
}

variable "service" {
  type        = "string"
  default     = "infrastructure"
  description = "Service VPC is used for"
}

variable "subnet_bits" {
  type        = "string"
  description = "Number of bits between the VPC bitmask and the desired subnet bitmask."
  default     = 8
}

variable "tenancy" {
  type        = "string"
  description = "Instance tenancy for the VPC. Only 'default' or 'dedicated' are valid"
  default     = "default"
}

variable "vpc_base_cidr" {
  type        = "string"
  description = "Base CIDR block to build VPC and subnets from."
  default     = "10.0.0.0/8"
}

variable "vpc_bits" {
  type        = "string"
  description = "The bits to extend the vpc_base_cidr network when building the VPC. See https://www.terraform.io/docs/configuration/interpolation.html#cidrsubnet_iprange_newbits_netnum_ for details."
  default     = "8"
}

variable "vpc_block" {
  type        = "string"
  description = "third octect in 10.x.vpc_block.x for vpc creation"
}

variable "vpc_net_num" {
  type        = "string"
  description = "second octect in 10.vpc_net_num.x.x for VPC creation"
}

# Configure the AWS provider
provider "aws" {
  version = "~> 1.2"
  region  = "${var.region}"
}

##############################################################################
# VPC and subnet configuration
##############################################################################
resource "aws_vpc" "VPC" {
  cidr_block           = "${cidrsubnet(var.vpc_base_cidr, var.vpc_bits, var.vpc_net_num)}"
  instance_tenancy     = "${var.tenancy}"
  enable_dns_support   = "true"
  enable_dns_hostnames = "true"

  tags {
    Environment = "${var.environment}"
    Name        = "${var.environment}-${var.name}VPC"
    Platform    = "ots"
    Role        = "networking"
    Service     = "${var.service}"
    terraform   = "true"
  }
}

# private subnets
resource "aws_subnet" "private_subnets" {
  count             = "${length(var.azones)}"
  vpc_id            = "${aws_vpc.VPC.id}"
  cidr_block        = "${cidrsubnet(aws_vpc.VPC.cidr_block, var.subnet_bits, var.vpc_block + count.index)}"
  availability_zone = "${element(var.azones, count.index)}"

  tags {
    Environment = "${var.environment}"
    Name        = "${var.environment}-${var.name}Private_${element(var.azones, count.index)}"
    Platform    = "ots"
    Role        = "networking"
    Service     = "${var.service}"
    terraform   = "true"
  }
}

# public subnets
resource "aws_subnet" "public_subnets" {
  count                   = "${length(var.azones)}"
  vpc_id                  = "${aws_vpc.VPC.id}"
  cidr_block              = "${cidrsubnet(aws_vpc.VPC.cidr_block, var.subnet_bits, var.vpc_block + count.index + 10)}"
  availability_zone       = "${element(var.azones, count.index)}"
  map_public_ip_on_launch = true

  tags {
    Environment = "${var.environment}"
    Name        = "${var.environment}-${var.name}Public_${element(var.azones, count.index)}"
    Platform    = "ots"
    Role        = "networking"
    Service     = "${var.service}"
    terraform   = "true"
  }
}

# gateway for public subnet
resource "aws_internet_gateway" "IG" {
  vpc_id = "${aws_vpc.VPC.id}"

  tags {
    Environment = "${var.environment}"
    Name        = "${var.environment}-${var.name}IG"
    Platform    = "ots"
    Role        = "networking"
    Service     = "${var.service}"
    terraform   = "true"
  }

  depends_on = [
    "aws_subnet.public_subnets",
  ]
}

# eips for the nat gateways
resource "aws_eip" "nat_eip" {
  count = "${length(var.azones)}"
  vpc   = true
}

resource "aws_nat_gateway" "vpn_nat" {
  count         = "${length(var.azones)}"
  allocation_id = "${element(aws_eip.nat_eip.*.id, count.index)}"
  subnet_id     = "${element(aws_subnet.public_subnets.*.id, count.index)}"

  depends_on = [
    "aws_internet_gateway.IG",
  ]
}

#########
# routes
#########

# public route
resource "aws_route_table" "vpc-public-route" {
  vpc_id = "${aws_vpc.VPC.id}"

  tags {
    Environment = "${var.environment}"
    Name        = "${var.environment}-${var.name}Public"
    Platform    = "ots"
    Role        = "networking"
    Service     = "${var.service}"
    terraform   = "true"
  }
}

# route public traffic through internet gateway
resource "aws_route" "public-route" {
  route_table_id         = "${aws_route_table.vpc-public-route.id}"
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = "${aws_internet_gateway.IG.id}"
  depends_on             = ["aws_route_table.vpc-public-route", "aws_internet_gateway.IG"]
}

# associate routes with public subnets
resource "aws_route_table_association" "vpc-public-route-assoc" {
  count          = "${length(var.azones)}"
  subnet_id      = "${element(aws_subnet.public_subnets.*.id, count.index)}"
  route_table_id = "${aws_route_table.vpc-public-route.id}"
}

# route to bastion and environment over the private interface
resource "aws_route_table" "private-route" {
  vpc_id = "${aws_vpc.VPC.id}"

  tags {
    Environment = "${var.environment}"
    Name        = "${var.environment}-${var.name}Private"
    Platform    = "ots"
    Role        = "networking"
    Service     = "${var.service}"
    terraform   = "true"
  }

  depends_on = ["aws_nat_gateway.vpn_nat"]
}

# route public traffic through internet gateway
resource "aws_route" "private-public-route" {
  route_table_id         = "${aws_route_table.private-route.id}"
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = "${element(aws_nat_gateway.vpn_nat.*.id, count.index)}"
  depends_on             = ["aws_route_table.private-route", "aws_nat_gateway.vpn_nat"]
}

# associate route table with private subnets
resource "aws_route_table_association" "private-route-assoc" {
  count          = "${length(var.azones)}"
  subnet_id      = "${element(aws_subnet.private_subnets.*.id, count.index)}"
  route_table_id = "${aws_route_table.private-route.id}"
}

# Output info for use upstream
output "private_route_table_id" {
  value = "${aws_route_table.private-route.id}"
}

output "private_subnet_blocks" {
  value = ["${aws_subnet.private_subnets.*.cidr_block}"]
}

output "private_subnet_ids" {
  value = ["${aws_subnet.private_subnets.*.id}"]
}

output "public_subnet_blocks" {
  value = ["${aws_subnet.private_subnets.*.cidr_block}"]
}

output "public_subnet_ids" {
  value = ["${aws_subnet.private_subnets.*.id}"]
}

output "vpc_id" {
  value = "${aws_vpc.VPC.id}"
}
