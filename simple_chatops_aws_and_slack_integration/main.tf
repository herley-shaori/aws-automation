provider "aws" {
  region = "ap-southeast-3" # Jakarta
}

resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
}

resource "aws_internet_gateway" "gw" {
  vpc_id = aws_vpc.main.id
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  map_public_ip_on_launch = true
  availability_zone       = "ap-southeast-3a"
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
}

resource "aws_route" "internet_access" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.gw.id
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_security_group" "ec2_sg" {
  name        = "ec2-public-sg"
  description = "Allow SSH and HTTP"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

data "aws_ami" "amazon_linux_2" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["amzn2-ami-hvm-*-x86_64-gp2"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_instance" "ec2" {
  count             = 2
  ami               = data.aws_ami.amazon_linux_2.id
  instance_type     = "t3.2xlarge"
  subnet_id         = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.ec2_sg.id]
  associate_public_ip_address = true
  tags = {
    Name = "public-ec2-${count.index + 1}"
  }
}

# Lambda IAM policy for EC2 describe
resource "aws_iam_policy" "lambda_ec2_describe" {
  name        = "lambda-ec2-describe"
  description = "Allow Lambda to describe EC2 instances"
  policy      = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Action = [
          "ec2:DescribeInstances"
        ],
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_ec2_describe" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = aws_iam_policy.lambda_ec2_describe.arn
}

resource "local_file" "lambda_code" {
  filename = "${path.module}/inline_lambda.py"
  content  = <<EOF
import json
import logging
import boto3
import re

def lambda_handler(event, context):
    logging.basicConfig(level=logging.INFO)
    ec2 = boto3.client('ec2')
    response = ec2.describe_instances(Filters=[{'Name': 'instance-state-name', 'Values': ['running']}])
    result = []
    account_id = context.invoked_function_arn.split(":")[4]
    for reservation in response['Reservations']:
        for instance in reservation['Instances']:
            arn = f"arn:aws:ec2:{instance['Placement']['AvailabilityZone'][:-1]}:*******:instance/{instance['InstanceId']}"
            public_ip = instance.get('PublicIpAddress', None)
            result.append({'arn': arn, 'public_ip': public_ip})
    return {
        'statusCode': 200,
        'body': json.dumps(result)
    }
EOF
}

resource "null_resource" "zip_lambda" {
  depends_on = [local_file.lambda_code]
  provisioner "local-exec" {
    command = "cd ${path.module} && zip -j inline_lambda.zip inline_lambda.py"
  }
  triggers = {
    lambda_code_hash = local_file.lambda_code.content_base64sha256
  }
}

resource "aws_lambda_function" "inline_python" {
  function_name = "inline-python-lambda"
  runtime       = "python3.12"
  role          = aws_iam_role.lambda_exec.arn
  handler       = "inline_lambda.lambda_handler"
  timeout       = 60
  filename      = "${path.module}/inline_lambda.zip"
  source_code_hash = local_file.lambda_code.content_base64sha256
  depends_on    = [null_resource.zip_lambda]
}

resource "aws_iam_role" "lambda_exec" {
  name = "lambda-exec-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect = "Allow",
      Principal = { Service = "lambda.amazonaws.com" },
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy_attachment" "lambda_logs" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchFullAccess"
}

resource "aws_apigatewayv2_api" "lambda_api" {
  name          = "inline-python-lambda-api"
  protocol_type = "HTTP"
}

resource "aws_apigatewayv2_integration" "lambda_integration" {
  api_id                 = aws_apigatewayv2_api.lambda_api.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.inline_python.invoke_arn
  integration_method     = "POST"
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "lambda_route" {
  api_id    = aws_apigatewayv2_api.lambda_api.id
  route_key = "POST /"
  target    = "integrations/${aws_apigatewayv2_integration.lambda_integration.id}"
}

resource "aws_apigatewayv2_stage" "lambda_stage" {
  api_id      = aws_apigatewayv2_api.lambda_api.id
  name        = "$default"
  auto_deploy = true
}

resource "aws_lambda_permission" "apigw_invoke" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.inline_python.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.lambda_api.execution_arn}/*/*"
}

resource "aws_ssm_parameter" "slack_app_credentials" {
  name        = "/slack/app/credentials"
  type        = "SecureString"
  value       = file("${path.module}/slack_app_credentials.json")
  description = "Slack app credentials for ChatOps integration"
}
