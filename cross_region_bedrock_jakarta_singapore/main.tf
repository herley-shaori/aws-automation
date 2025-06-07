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
from botocore.exceptions import ClientError

def lambda_handler(event, context):
    # API Gateway HTTP API (v2.0) puts the request body as a string in event['body']
    prompt = "hello world"
    if "body" in event and event["body"]:
        try:
            body_json = json.loads(event["body"])
            prompt = body_json.get("prompt", prompt)
        except Exception:
            pass
    elif "prompt" in event:
        prompt = event["prompt"]
    bedrock = boto3.client(
        "bedrock-runtime",
        region_name="ap-southeast-1"  # Singapore
    )
    model_id = "apac.anthropic.claude-sonnet-4-20250514-v1:0"
    native_request = {
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
                        "text": prompt
                    }
                ]
            }
        ]
    }
    request = json.dumps(native_request)
    try:
        response = bedrock.invoke_model(modelId=model_id, body=request)
        model_response = json.loads(response["body"].read())
        response_text = model_response["content"][0]["text"]
        return {
            'statusCode': 200,
            'body': response_text
        }
    except (ClientError, Exception) as e:
        return {
            'statusCode': 500,
            'body': f"ERROR: Can't invoke '{model_id}'. Reason: {e}"
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
  timeout       = 60

  depends_on = [null_resource.zip_inline_lambda]
}

resource "aws_apigatewayv2_api" "lambda_api" {
  name          = "bedrock-caller-api"
  protocol_type = "HTTP"
}

resource "aws_apigatewayv2_integration" "lambda_integration" {
  api_id                 = aws_apigatewayv2_api.lambda_api.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.hello_world.invoke_arn
  integration_method     = "POST"
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "lambda_route" {
  api_id    = aws_apigatewayv2_api.lambda_api.id
  route_key = "POST /invoke"
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
  function_name = aws_lambda_function.hello_world.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.lambda_api.execution_arn}/*/*"
}