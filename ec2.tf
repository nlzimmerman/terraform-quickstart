# This is only used for output, it would rebuild the EC2 instances
# every time this changed if this was directly passed into an EC2 argument.
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

variable ami {
  type = string
  description = "the AMI to use."
  default = "ami-0fb1e27304d83032f"
}

# you could spot-check whether this is still the newest and update on a re-deploy
output latest_ubuntu_ami {
  value = data.aws_ami.ubuntu.id
}

variable ec2_instance_type {
  type = string
  default = "t2.nano"
}

variable ec2_ssh_key {
  type = string
  description = "the SSH key to get in"
}

resource random_pet ssh_key_name {
  keepers = {ssh_key = var.ec2_ssh_key}
}

resource aws_key_pair deployer {
  key_name   = random_pet.ssh_key_name.id
  public_key = var.ec2_ssh_key
}

resource aws_instance public_instances {
  count = local.az_count
  ami           = var.ami
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
  ami           = var.ami
  instance_type = var.ec2_instance_type
  subnet_id = aws_subnet.private_subnets[count.index].id
  vpc_security_group_ids = [aws_security_group.allow_ssh.id]
  key_name = aws_key_pair.deployer.key_name
  tags = {
    Name = "Private instance ${local.availability_zones[count.index]}"
  }
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
