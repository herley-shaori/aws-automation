provider "aws" {
  region = "ap-southeast-3" # Jakarta
}

resource "random_id" "suffix" {
  byte_length = 4
}

resource "aws_iam_role" "lambda_exec" {
  name = "lambda_exec_role_${random_id.suffix.hex}"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_basic_execution" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_policy" "lambda_logs_cloudwatch" {
  name        = "lambda_logs_cloudwatch_policy"
  description = "Allow Lambda to access logs, CloudWatch, and Bedrock"
  policy      = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Action = [
          "logs:*",
          "cloudwatch:*",
          "bedrock:*"
        ],
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_logs_cloudwatch_attachment" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = aws_iam_policy.lambda_logs_cloudwatch.arn
}

resource "local_file" "inline_lambda_code" {
  content  = <<EOF
import json
import boto3

def lambda_handler(event, context):
    bedrock = boto3.client(
        "bedrock-runtime",
        region_name="ap-southeast-1"  # Singapore
    )
    # Build the request body as required by Bedrock Claude Sonnet 4
    body = {
        "anthropic_version": "bedrock-2023-05-31",
        "max_tokens": 200,
        "top_k": 250,
        "stop_sequences": [],
        "temperature": 1,
        "top_p": 0.999,
        "messages": [
            {
                "role": "user",
                "content": [
                    {
                        "type": "text",
                        "text": event.get("prompt", "hello world")
                    }
                ]
            }
        ]
    }
    response = bedrock.invoke_model(
        modelId="anthropic.claude-sonnet-4-20250514-v1:0",
        contentType="application/json",
        accept="application/json",
        body=json.dumps(body)
    )
    result = response["body"].read().decode()
    return {
        'statusCode': 200,
        'body': result
    }
EOF
  filename = "${path.module}/index.py"
}

resource "null_resource" "zip_inline_lambda" {
  triggers = {
    source = local_file.inline_lambda_code.content
  }
  provisioner "local-exec" {
    command = "zip -j ${path.module}/inline_lambda.zip ${path.module}/index.py"
  }
}

resource "aws_lambda_function" "hello_world" {
  function_name = "bedrock_caller"
  role          = aws_iam_role.lambda_exec.arn
  handler       = "index.lambda_handler"
  runtime       = "python3.12"
  filename      = "inline_lambda.zip"
  source_code_hash = filebase64sha256("${path.module}/inline_lambda.zip")

  depends_on = [null_resource.zip_inline_lambda]
}