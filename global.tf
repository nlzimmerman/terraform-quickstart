terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 3.31"
    }
    random = {
      source = "hashicorp/random"
      version = "~> 3.1.0"
    }
  }
}

provider "aws" {
  profile = "default"
  region  = var.aws_region
}

variable aws_region {
  type = string
  default = "us-east-2"
}
