# 🚀 Cross-Region Bedrock API Access with Lambda & API Gateway

## Goal
Use AWS Bedrock API (Claude Sonnet 4) in the Singapore region (`ap-southeast-1`) from a Lambda function deployed in the Jakarta region (`ap-southeast-3`). All traffic flows over the public internet. 🌏➡️🌐

---

## Architecture Overview

- **Lambda Function** (Python 3.12, Jakarta):
  - Inline code in Terraform (`main.tf`)
  - Calls Bedrock API in Singapore using `boto3`
  - Handles prompts and returns Claude Sonnet 4 responses
  - Timeout set to 60 seconds
- **IAM Role & Policy**:
  - Lambda execution role with permissions for `logs:*`, `cloudwatch:*`, and `bedrock:*`
- **API Gateway (HTTP API v2)**:
  - Exposes a public POST endpoint `/invoke` as frontend for Lambda
  - Allows easy testing from anywhere

---

## How It Works

1. **Lambda Function**
   - Deployed in Jakarta (`ap-southeast-3`)
   - Uses `boto3` to call Bedrock API in Singapore (`ap-southeast-1`)
   - Sends prompt and receives response from Claude Sonnet 4
2. **API Gateway**
   - HTTP API with POST `/invoke` route
   - Integrated as AWS_PROXY with Lambda
   - Publicly accessible endpoint
3. **IAM**
   - Lambda role allows all required actions, including `bedrock:InvokeModel`

---

## Example Lambda Code (inline in Terraform)
```python
import json
import boto3
from botocore.exceptions import ClientError

def lambda_handler(event, context):
    bedrock = boto3.client(
        "bedrock-runtime",
        region_name="ap-southeast-1"  # Singapore
    )
    model_id = "apac.anthropic.claude-sonnet-4-20250514-v1:0"
    prompt = event.get("prompt", "hello world")
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
```

---

## API Gateway Endpoint

- **Invoke URL:**
  ```
  https://v51h39sd4f.execute-api.ap-southeast-3.amazonaws.com/invoke
  ```

- **Test with curl:**
  ```sh
  curl -X POST "https://v51h39sd4f.execute-api.ap-southeast-3.amazonaws.com/invoke" \
    -H "Content-Type: application/json" \
    -d '{"prompt": "hello world"}'
  ```
  _(Change the prompt as needed!)_

---

## Example API Call & Result

**Request:**
```sh
curl -X POST "https://v51h39sd4f.execute-api.ap-southeast-3.amazonaws.com/invoke" \
  -H "Content-Type: application/json" \
  -d '{"prompt": "where is jakarta?"}'
```

**Response:**
```
Jakarta is the capital and largest city of Indonesia. It's located on the northwest coast of the island of Java, along the Java Sea. The city sits at the mouth of the Ciliwung River and serves as Indonesia's political, economic, and cultural center. Jakarta is home to over 10 million people in the city proper, with the greater metropolitan area housing around 30 million people, making it one of the world's largest urban agglomerations.
```

---

## Terraform Highlights
- Provider: `ap-southeast-3` (Jakarta)
- Lambda: Python 3.12, inline code, zipped and deployed
- IAM: Full Bedrock, CloudWatch, and Logs permissions
- API Gateway: HTTP API, POST `/invoke`, Lambda proxy integration

---

## 🌟 Summary
- Secure, cross-region Bedrock API access from Jakarta to Singapore
- Fully automated with Terraform
- Easy to test and extend

---

📝 _Last updated: June 7, 2025_
