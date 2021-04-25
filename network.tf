### Inputs

# https://medium.com/@aliatakan/terraform-create-a-vpc-subnets-and-more-6ef43f0bf4c1
# https://registry.terraform.io/providers/hashicorp/aws/latest/docs

# the CIDR block to use for your VPC. VPCs go up to a /16. You could make it smaller
# if you wanted.
# remember: *define* variables with `variable`. *reference* them with `var`
variable vpc_cidr_block {
  type = string
  default = "10.250.0.0/16"
}

# the next two inputs define which AZs to use.
# if this variable is non-empty, it takes strict precedence over az_count
variable availability_zones_to_use {
  type = list(string)
  default = []
}

# if availability_zones_to_use is unset, we randomly select this many azs from the available zones.
variable availability_zone_count {
  type = number
  default = 1
}

# END inputs.

# BEGIN subnets and routing.
# randomly select N AZs. This is only actually used in the case where
# var.availability_zones_to_use is empty, but since Terraform defines all variables at once
# (and there are no if/else blocks), it's simplest to just define this and use it if we need it.

data aws_availability_zones available {}

resource random_shuffle availability_zones {
  input = data.aws_availability_zones.available.names
  result_count = var.availability_zone_count
}

# Define our VPC
resource aws_vpc vpc {
  cidr_block = var.vpc_cidr_block
  enable_dns_support = true
  enable_dns_hostnames = true
  tags = {
    Name = "Terraform test VPC"
  }
}


# figure out our networking information.
# remember: `locals {whatever = value}` to define local variables. `local.whatever` to use them
locals {
  # the actual number of AZs we'll use.
  # instead of if/else statements, Terraform has ternary operators
  az_count = length(var.availability_zones_to_use) == 0 ? var.availability_zone_count : length(var.availability_zones_to_use)
  # the specific order of availability zones, because we shuffle them if we specify availability_zone_count but not availability_zones_to_use
  availability_zones = length(var.availability_zones_to_use) == 0 ? random_shuffle.availability_zones.result : var.availability_zones_to_use
  # split the CIDR block in half, one for public and one for private
  private_cidr_block = cidrsubnet(var.vpc_cidr_block, 1, 0)
  public_cidr_block = cidrsubnet(var.vpc_cidr_block, 1, 1)
  # subdivide public and private into even powers-of-two blocks
  # these are lists of tuples because we want to preserve ordering between private and public
  private_subnet_cidr = [for i in range(local.az_count) : [local.availability_zones[i], cidrsubnet(local.private_cidr_block, ceil(log(local.az_count, 2)), i)]]
  public_subnet_cidr = [for i in range(local.az_count) : [local.availability_zones[i], cidrsubnet(local.public_cidr_block, ceil(log(local.az_count, 2)), i)]]
}

# Define the public subnets

resource aws_subnet public_subnets {
  # Big idea: if you specify a count you're making a list of this resource.
  # if you specify a for_each argument, you're making an (unordered) set of this resource.
  # if you specify neither, you are making precisely one of this resource, and it's not in a collection.
  # I try to make a habit of using the trailing "s" to indicate that I've made a collection.
  # https://www.terraform.io/docs/language/meta-arguments/count.html
  # https://www.terraform.io/docs/language/meta-arguments/for_each.html
  count = local.az_count
  availability_zone = local.private_subnet_cidr[count.index][0]
  cidr_block = local.public_subnet_cidr[count.index][1]
  vpc_id = aws_vpc.vpc.id
  # This makes it public
  map_public_ip_on_launch = true
  tags = {
    Name = "Terraform test public subnet ${local.availability_zones[count.index]}"
  }
}

resource aws_internet_gateway igw {
  vpc_id = aws_vpc.vpc.id
}

# we have *one* route table here because all public subnets route their
# traffic to the same IGW.
resource aws_route_table public_route_table {
  vpc_id = aws_vpc.vpc.id
  tags = {
    Name = "public route table"
  }
}

resource aws_route public_route {
  route_table_id = aws_route_table.public_route_table.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id = aws_internet_gateway.igw.id
}

# we associate this same public route table with each public subnet.
resource aws_route_table_association public_route_association {
  count = local.az_count
  subnet_id = aws_subnet.public_subnets[count.index].id
  route_table_id = aws_route_table.public_route_table.id
}

# END public subnets

# Private subnets

resource aws_subnet private_subnets {
  count = local.az_count
  availability_zone = local.private_subnet_cidr[count.index][0]
  cidr_block = local.private_subnet_cidr[count.index][1]
  vpc_id = aws_vpc.vpc.id
  # This makes it private.
  map_public_ip_on_launch = false
  tags = {
    Name = "Terraform test private subnet ${local.availability_zones[count.index]}"
  }
}

# Private subnets require NAT gateways to get to the public internet.
# NAT gateways require Elastic IPs. Elastic IPs are themselves not associated with
# any availability zone, but we need one for each NAT gateway.
# https://dev.betterdoc.org/infrastructure/2020/02/04/setting-up-a-nat-gateway-on-aws-using-terraform.html
# Note that you're allowed to use the same name for resources of different types.
# `aws_eip.nat_gateways` does not conflict with `aws_nat_gateway.nat_gateways`
# They're always referenced by type so this makes sense.
resource aws_eip nat_gateways {
  count = local.az_count
  vpc = true
}

# NAT gateways live in *public* subnets so that they can route to the internet.
resource aws_nat_gateway nat_gateways {
  # we want one NAT gateway per AZ so that routing would still work if one AZ went down.
  # In practice, we only want one AZ for our test project anyway.
  count = local.az_count
  # allocation_id refers to the EIP. Terraform API documentation is pretty good; you'll
  # definitely have to refer to it often.
  allocation_id = aws_eip.nat_gateways[count.index].id
  subnet_id = aws_subnet.public_subnets[count.index].id
  tags = {
    Name = "Terraform NAT Gateway ${local.availability_zones[count.index]}"
  }
}

# We need as many private route tables as we have AZs, because each private subnet
# should route to the NAT gateway in the same AZ.
# Route tables themselves are global to a VPC, it's the association that
# binds them to a subnet.
resource aws_route_table private_route_tables {
  count = local.az_count
  vpc_id = aws_vpc.vpc.id
  tags = {
    Name = "private route table ${local.availability_zones[count.index]}"
  }
}

# One private route per subnet for the same reason.
resource aws_route private_routes {
  count = local.az_count
  route_table_id = aws_route_table.private_route_tables[count.index].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id = aws_nat_gateway.nat_gateways[count.index].id
}

# Associate the private route with the private subnet in the same AS.
resource aws_route_table_association private_route_associations {
  count = local.az_count
  subnet_id = aws_subnet.private_subnets[count.index].id
  route_table_id = aws_route_table.private_route_tables[count.index].id
}

# END subnets and routing.

# Begin security groups
# Note that we declare these here, but security groups aren't bound to subnets,
# they're bound to compute resources. (EC2 instances etc.)

# You declare a security group and associate some number of rules with it.
resource aws_security_group allow_ssh {
  name = "allow_ssh"
  description = "Let people SSH in"
  vpc_id = aws_vpc.vpc.id
}

# SSH in from anywhere
resource aws_security_group_rule ssh_in {
  type = "ingress"
  from_port = 22
  to_port = 22
  protocol = "tcp"
  cidr_blocks = ["0.0.0.0/0"]
  security_group_id = aws_security_group.allow_ssh.id
}

# All traffic originating inside this VPC is permitted.
resource aws_security_group_rule allow_local {
  type = "ingress"
  from_port = 0
  to_port = 65535
  protocol = "tcp"
  cidr_blocks = [aws_vpc.vpc.cidr_block]
  security_group_id = aws_security_group.allow_ssh.id
}

# All outbound traffic is permitted.
resource aws_security_group_rule allow_egress {
  type = "egress"
  from_port = 0
  to_port = 65535
  protocol = "-1"
  cidr_blocks = ["0.0.0.0/0"]
  security_group_id = aws_security_group.allow_ssh.id
}

# This output is just diagnostic, in production you probably wouldn't want it unless
# you turned networking into its own module. 
output ordered_availability_zones {
  value = local.availability_zones
}

output private_networks {
  value = {
    for i in range(local.az_count): local.availability_zones[i] =>
    {
      public_subnet = aws_subnet.public_subnets[i].id
      public_subnet_cidr = local.public_subnet_cidr[i][1]
      private_subnet = aws_subnet.private_subnets[i].id
      private_subnet_cidr = local.private_subnet_cidr[i][1]
      gateway = aws_nat_gateway.nat_gateways[i].id
      route_table_id = aws_route_table.private_route_tables[i].id
    }
  }
}
