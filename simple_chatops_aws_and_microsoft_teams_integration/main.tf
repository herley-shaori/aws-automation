provider "aws" {
  region = "ap-southeast-3" # Jakarta
}

resource "local_file" "lambda_code" {
  filename = "${path.module}/inline_lambda.py"
  content  = <<EOF
import json
def lambda_handler(event, context):
    return {
        'statusCode': 200,
        'body': json.dumps('Hello from inline Python Lambda!')
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
