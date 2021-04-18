# https://medium.com/@aliatakan/terraform-create-a-vpc-subnets-and-more-6ef43f0bf4c1
# https://registry.terraform.io/providers/hashicorp/aws/latest/docs
resource aws_vpc vpc {
  cidr_block = "10.250.0.0/16"
  enable_dns_support = true
  enable_dns_hostnames = true
}

data aws_availability_zones available {}

variable availability_zone_names {
  type = list(string)
  default = []
}

variable az_count {
  type = number
  default = 1
}

resource random_shuffle availability_zones {
  input = local.valid_availability_zones
  result_count = local.valid_az_count
}

# If you don't specify availability zones, use all of them.
locals {
  valid_availability_zones = length(var.availability_zone_names) == 0 ? data.aws_availability_zones.available.names : var.availability_zone_names
  valid_az_count = max(min(var.az_count, length(local.valid_availability_zones)), 1)
  availability_zones = random_shuffle.availability_zones.result
}

output availability_zones {
  value = random_shuffle.availability_zones.result
}

output valid_az_count {
  value = local.valid_az_count
}

resource aws_subnet private_subnets {
  # https://www.terraform.io/docs/language/meta-arguments/count.html
  # https://www.terraform.io/docs/language/meta-arguments/for_each.html
  count = local.valid_az_count
  cidr_block = cidrsubnet("10.250.0.0/17", ceil(log(length(local.availability_zones), 2)), count.index)
  vpc_id = aws_vpc.vpc.id
  map_public_ip_on_launch = false
  availability_zone = data.aws_availability_zones.available.names[count.index]
}

resource aws_subnet public_subnets {
  # https://www.terraform.io/docs/language/meta-arguments/count.html
  # https://www.terraform.io/docs/language/meta-arguments/for_each.html
  count = local.valid_az_count
  cidr_block = cidrsubnet("10.250.128.0/17", ceil(log(length(local.availability_zones), 2)), count.index)
  vpc_id = aws_vpc.vpc.id
  map_public_ip_on_launch = true
  availability_zone = local.availability_zones[count.index]
}


resource aws_internet_gateway igw {
  vpc_id = aws_vpc.vpc.id
}

# https://dev.betterdoc.org/infrastructure/2020/02/04/setting-up-a-nat-gateway-on-aws-using-terraform.html
resource aws_eip nat_gateways {
  # there's nothing stopping you from making this
  count = local.valid_az_count
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
