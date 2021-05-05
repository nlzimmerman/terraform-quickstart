# https://www.andreagrandi.it/2017/08/25/getting-latest-ubuntu-ami-with-terraform/
# Find the latest Ubuntu 20.04 AMI. Note that if you *don't* specify
data aws_ami ubuntu {
  most_recent = true
  filter {
    name = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-focal-20.04-amd64-server-*"]
  }
  filter {
    name = "virtualization-type"
    values = ["hvm"]
  }
  owners = ["099720109477"]
}

# The AMI to use. In production, you would not want to directly use `data.aws_ami.ubuntu.id`
# because every time that changes your EC2 instances would be rebuilt, you'd instead
# want to specify it yourself and only update when you had a reason.
variable ami {
  type = string
  description = "The AMI to use. Default is the empty string, which means we'll use whatever the latest one is."
  default = ""
}

# This is the same pattern as in networking.tf — if we specified an AMI, use it, otherwise, use the default.
locals {
  ami = coalesce(var.ami, data.aws_ami.ubuntu.id)
}

# you could spot-check whether this is still the newest and use that information
# to decide whether you need to manually update and re-deploy
output latest_ubuntu_ami {
  value = data.aws_ami.ubuntu.id
}

variable ec2_instance_type {
  type = string
  default = "t2.nano"
}

# This variable is not optional, there is no default.
variable ec2_ssh_key {
  type = string
  description = "the SSH key to get in"
}

# key names are the primary identifiers of ssh keys — names aren't just made for you
# in order to get a safe, random name, we use the random_pet module
resource random_pet ssh_key_name {
  keepers = {
    ssh_key = var.ec2_ssh_key
  }
}

resource aws_key_pair deployer {
  key_name   = random_pet.ssh_key_name.id
  public_key = var.ec2_ssh_key
}

resource aws_instance public_instances {
  count = local.az_count
  ami = local.ami
  instance_type = var.ec2_instance_type
  subnet_id = aws_subnet.public_subnets[count.index].id
  vpc_security_group_ids = [aws_security_group.allow_ssh.id]
  key_name = aws_key_pair.deployer.key_name
  tags = {
    Name = "Public instance ${local.availability_zones[count.index]}"
  }
}

resource aws_instance private_instances {
  count = local.az_count
  ami = local.ami
  instance_type = var.ec2_instance_type
  subnet_id = aws_subnet.private_subnets[count.index].id
  vpc_security_group_ids = [aws_security_group.allow_ssh.id]
  key_name = aws_key_pair.deployer.key_name
  tags = {
    Name = "Private instance ${local.availability_zones[count.index]}"
  }
  # access the secrets store described in secrets.tf
  iam_instance_profile = aws_iam_instance_profile.ec2_instance_profile.name
}

output ec2_ip_addresses {
  value = {
    public = {
      for i in range(local.az_count) : local.availability_zones[i] => [aws_instance.public_instances[i].public_ip, aws_instance.public_instances[i].private_ip]
    }
    private = {
      for i in range(local.az_count) : local.availability_zones[i] => aws_instance.private_instances[i].private_ip
    }
  }
}
