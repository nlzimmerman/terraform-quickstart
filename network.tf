# https://medium.com/@aliatakan/terraform-create-a-vpc-subnets-and-more-6ef43f0bf4c1
# https://registry.terraform.io/providers/hashicorp/aws/latest/docs
resource aws_vpc vpc {
  cidr_block = "10.250.0.0/16"
  enable_dns_support = true
  enable_dns_hostnames = true
}

data aws_availability_zones available {}

resource aws_subnet private_subnets {
  # https://www.terraform.io/docs/language/meta-arguments/count.html
  # https://www.terraform.io/docs/language/meta-arguments/for_each.html
  count = length(data.aws_availability_zones.available.names)
  cidr_block = cidrsubnet("10.250.0.0/17", ceil(log(length(data.aws_availability_zones.available.names), 2)), count.index)
  vpc_id = aws_vpc.vpc.id
  map_public_ip_on_launch = false
  availability_zone = data.aws_availability_zones.available.names[count.index]
}

resource aws_subnet public_subnets {
  # https://www.terraform.io/docs/language/meta-arguments/count.html
  # https://www.terraform.io/docs/language/meta-arguments/for_each.html
  count = length(data.aws_availability_zones.available.names)
  cidr_block = cidrsubnet("10.250.128.0/17", ceil(log(length(data.aws_availability_zones.available.names), 2)), count.index)
  vpc_id = aws_vpc.vpc.id
  map_public_ip_on_launch = true
  availability_zone = data.aws_availability_zones.available.names[count.index]
}
