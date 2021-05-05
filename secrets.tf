# https://qalead.medium.com/terraform-aws-secretmanager-reading-secret-from-an-ec2-instance-using-iam-role-policy-and-a7a2b6922165

# Begin secret storage

resource aws_secretsmanager_secret our_secret {
  name = "example_secret"
  # If you don't set this to 0, secrets will not actually be destroyed when you
  # run `terraform destroy` — instead, the secret will stick around for seven days
  # https://aws.amazon.com/premiumsupport/knowledge-center/delete-secrets-manager-secret/
  # In production, this is very likely reasonable, but in dev, this means you're
  # going to get name collisions if you do a `terraform destroy` followed by a
  # `terraform apply`

  # TODO, rotation would be good
  # https://medium.com/@aysh/automating-secret-rotation-of-aws-rds-using-lambda-ba0276b06d69
  recovery_window_in_days = 0
}

variable secret_string {
  type = string
  description = "The secret we're hiding."
  sensitive = true
  # Both terraform and JSON like double quotes.
  default = "{\"username\": \"user\", \"password\": \"password\"}"
}

resource aws_secretsmanager_secret_version current_secret_version {
  secret_id = aws_secretsmanager_secret.our_secret.id
  secret_string = var.secret_string
}

# Create policies that allow our private-network EC2 instances to access the secret.

data aws_iam_policy_document ec2_assume_policy {
  statement {
    sid = ""
    effect = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource aws_iam_role ec2_secret_role {
  name = "test_iam_role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_policy.json
}

data aws_iam_policy_document access_secretsmanager {
  statement {
    effect = "Allow"
    actions = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.our_secret.id]
  }
}

resource aws_iam_policy lambda_secretmanager_policy {
  name = "test_secretmanager_policy"
  policy = data.aws_iam_policy_document.access_secretsmanager.json
}

resource aws_iam_role_policy_attachment ec2_secret_attachment {
  role = aws_iam_role.ec2_secret_role.id
  policy_arn = aws_iam_policy.lambda_secretmanager_policy.id
}

# IAM instance profiles are specific to EC2.
# Check out line 83 in ec2.tf to see where this gets used.
resource aws_iam_instance_profile ec2_instance_profile {
  name = "ec2_secrets_instance_profile"
  role = aws_iam_role.ec2_secret_role.id
}

output secret_id {
  value = aws_secretsmanager_secret.our_secret.id
}
