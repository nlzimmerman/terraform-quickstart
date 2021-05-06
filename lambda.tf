# https://learn.hashicorp.com/tutorials/terraform/lambda-api-gateway?in=terraform/aws

data archive_file lambda_zip {
  type = "zip"
  source_file = "${path.module}/lambda.py"
  output_path = "${path.module}/lambda.zip"
}

# The name of both the function and the log group.

locals {
  lambda_function_name = "SecureQueryExample"
}

resource aws_lambda_function example {
   function_name = local.lambda_function_name
   filename = "lambda.zip"
   handler = "lambda.lambda_handler"
   runtime = "python3.8"
   # when source_code_hash changes, the resource changes.
   # This could alternatively be filebase64sha256("lambda.zip")
   source_code_hash = data.archive_file.lambda_zip.output_base64sha256

   role = aws_iam_role.lambda_exec.arn

   timeout = 30
   depends_on = [
    aws_iam_role_policy_attachment.lambda_logs,
    aws_iam_role_policy_attachment.lambda_secret,
    aws_cloudwatch_log_group.secure_query_example,
  ]
}

output lambda_function_id {
  value = aws_lambda_function.example.id
}

# This is the role that the lambda function will assume.

data aws_iam_policy_document assumption_policy {
  statement {
    sid = ""
    effect = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

# The role our lambda function assumes

resource aws_iam_role lambda_exec {
  name = "serverless_example_lambda"
  assume_role_policy = data.aws_iam_policy_document.assumption_policy.json
}

# Attach the same secrets-read policy to it.

resource aws_iam_role_policy_attachment lambda_secret {
  role = aws_iam_role.lambda_exec.name
  policy_arn = aws_iam_policy.lambda_secretmanager_policy.id
}

# We need a log group with the same name so that logs get written.

resource aws_cloudwatch_log_group secure_query_example {
  name              = "/aws/lambda/${local.lambda_function_name}"
  retention_in_days = 14
}

# We also need permission to actually write logs.

data aws_iam_policy_document permit_logs {
  statement {
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents"
    ]
    # this scopes it just to the log group we made in the previous statement
    resources = ["${aws_cloudwatch_log_group.secure_query_example.arn}:*"]
  }
}

# See also the following AWS managed policy: AWSLambdaBasicExecutionRole
resource aws_iam_policy lambda_logging {
  name        = "lambda_logging"
  path        = "/"
  description = "IAM policy for logging from a lambda"
  policy = data.aws_iam_policy_document.permit_logs.json
}

output log_id {
  value = aws_cloudwatch_log_group.secure_query_example.arn
}

resource "aws_iam_role_policy_attachment" "lambda_logs" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = aws_iam_policy.lambda_logging.arn
}

# let our private EC2 instances invoke the lambda.
data aws_iam_policy_document call_lambda {
  statement {
    effect = "Allow"
    actions = ["lambda:InvokeFunction"]
    resources = [aws_lambda_function.example.arn]
  }
}

resource aws_iam_policy call_lambda_policy {
  name = "call_lambda_policy"
  policy = data.aws_iam_policy_document.call_lambda.json
}

resource aws_iam_role_policy_attachment call_secret_lambda_ec2 {
   role = aws_iam_role.ec2_secret_role.id
   policy_arn = aws_iam_policy.call_lambda_policy.id
}
