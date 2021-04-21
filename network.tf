# https://medium.com/@aliatakan/terraform-create-a-vpc-subnets-and-more-6ef43f0bf4c1
# https://registry.terraform.io/providers/hashicorp/aws/latest/docs

variable vpc_cidr_block {
  type = string
  default = "10.250.0.0/16"
}

resource aws_vpc vpc {
  cidr_block = var.vpc_cidr_block
  enable_dns_support = true
  enable_dns_hostnames = true
}

data aws_availability_zones available {}

# if this variable is non-empty, it takes strict precedence over az_count
variable availability_zones_to_use {
  type = list(string)
  default = []
}

# if azs_to_use is unset, we randomly select this many azs from the available zones.
variable availability_zone_count {
  type = number
  default = 1
}

resource random_shuffle availability_zones {
  input = data.aws_availability_zones.available.names
  result_count = var.availability_zone_count
}

locals {
  az_count = length(var.availability_zones_to_use) == 0 ? var.availability_zone_count : length(var.availability_zones_to_use)
  availability_zones = length(var.availability_zones_to_use) == 0 ? random_shuffle.availability_zones.result : var.availability_zones_to_use
  private_cidr_block = cidrsubnet(var.vpc_cidr_block, 1, 0)
  public_cidr_block = cidrsubnet(var.vpc_cidr_block, 1, 1)
}

output availability_zones {
  value = local.availability_zones
}

output private_subnets {
  value = zipmap(local.availability_zones, [for i in aws_subnet.private_subnets : i.id])
}

output public_subnets {
  value = zipmap(local.availability_zones, [for i in aws_subnet.public_subnets : i.id])
}


resource aws_subnet private_subnets {
  # https://www.terraform.io/docs/language/meta-arguments/count.html
  # https://www.terraform.io/docs/language/meta-arguments/for_each.html
  count = local.az_count
  cidr_block = cidrsubnet(local.private_cidr_block, ceil(log(length(local.availability_zones), 2)), count.index)
  vpc_id = aws_vpc.vpc.id
  map_public_ip_on_launch = false
  availability_zone = local.availability_zones[count.index]
}

resource aws_subnet public_subnets {
  # https://www.terraform.io/docs/language/meta-arguments/count.html
  # https://www.terraform.io/docs/language/meta-arguments/for_each.html
  count = local.az_count
  cidr_block = cidrsubnet(local.public_cidr_block, ceil(log(length(local.availability_zones), 2)), count.index)
  vpc_id = aws_vpc.vpc.id
  map_public_ip_on_launch = true
  availability_zone = local.availability_zones[count.index]
}


resource aws_internet_gateway igw {
  vpc_id = aws_vpc.vpc.id
}

# https://dev.betterdoc.org/infrastructure/2020/02/04/setting-up-a-nat-gateway-on-aws-using-terraform.html
resource aws_eip nat_gateways {
  count = local.az_count
  vpc = true
}

resource aws_nat_gateway nat_gateways {
  count = length(aws_subnet.private_subnets)
  allocation_id = aws_eip.nat_gateways[count.index].id
  subnet_id = aws_subnet.public_subnets[count.index].id
}

resource aws_route_table public_route_table {
  vpc_id = aws_vpc.vpc.id
}

resource aws_route public_route {
  route_table_id = aws_route_table.public_route_table.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id = aws_internet_gateway.igw.id
}

resource aws_route_table_association public_route_association {
  count = length(aws_subnet.public_subnets)
  subnet_id = aws_subnet.public_subnets[count.index].id
  route_table_id = aws_route_table.public_route_table.id
}

resource aws_route_table private_route_tables {
  count = length(aws_subnet.private_subnets)
  vpc_id = aws_vpc.vpc.id
}

resource aws_route private_route {
  count = length(aws_subnet.private_subnets)
  route_table_id = aws_route_table.private_route_tables[count.index].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id = aws_nat_gateway.nat_gateways[count.index].id
}
#
resource aws_route_table_association private_route_associations {
  count = length(aws_subnet.private_subnets)
  subnet_id = aws_subnet.private_subnets[count.index].id
  route_table_id = aws_route_table.private_route_tables[count.index].id
}

resource aws_security_group allow_ssh {
  name = "allow_ssh"
  description = "Let people SSH in"
  vpc_id = aws_vpc.vpc.id
}

resource aws_security_group_rule ssh_in {
  type = "ingress"
  from_port = 22
  to_port = 22
  protocol = "tcp"
  cidr_blocks = ["0.0.0.0/0"]
  security_group_id = aws_security_group.allow_ssh.id
}

resource aws_security_group_rule allow_local {
  type = "ingress"
  from_port = 0
  to_port = 65535
  protocol = "tcp"
  cidr_blocks = [aws_vpc.vpc.cidr_block]
  security_group_id = aws_security_group.allow_ssh.id
}

resource aws_security_group_rule allow_egress {
  type = "egress"
  from_port = 0
  to_port = 65535
  protocol = "-1"
  cidr_blocks = ["0.0.0.0/0"]
  security_group_id = aws_security_group.allow_ssh.id
}
