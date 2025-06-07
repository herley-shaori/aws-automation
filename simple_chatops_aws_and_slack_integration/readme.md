# Simple ChatOps with AWS Lambda, API Gateway, and Slack Integration 🚀

## Overview
This project demonstrates a simple ChatOps solution using AWS infrastructure and Slack. The goal is to allow users in a Slack channel to type a command (e.g., `ec2-info`) and receive real-time information about running EC2 instances in AWS, including their ARNs (with the account ID censored) and public IP addresses.

## Slack Prerequisites (Mandatory)
- **Create a Slack App** in your Slack workspace.
- **Create a Slack Channel** for ChatOps interactions.
- **Set up a Slack Webhook** to allow Slack to send events to your API Gateway endpoint.
- **Configure a Slack Slash Command** (e.g., `/ec2-info`) to trigger the webhook and send requests to your API Gateway endpoint.

## How It Works
1. **Slack Channel Setup**: A Slack channel is created for ChatOps. Users can type `ec2-info` to trigger the workflow.
2. **API Gateway**: An HTTP API Gateway endpoint is deployed to receive POST requests from Slack (via a Slack app or webhook integration).
3. **AWS Lambda Function**: The API Gateway triggers a Lambda function written in Python 3.12. This Lambda:
    - Lists all running EC2 instances in the Jakarta (ap-southeast-3) region.
    - Returns a JSON response with each instance's ARN (with the AWS account ID replaced by `*******`) and public IP address.
    - Logs all requests to CloudWatch for observability.
4. **IAM & Security**:
    - The Lambda function has permissions to describe EC2 instances and full access to CloudWatch Logs.
    - All infrastructure is deployed in a VPC with DNS support and public subnet for EC2.
    - Security groups allow SSH (22) and HTTP (80) access to EC2 instances.
5. **Slack App Credentials**: Slack app credentials are stored securely in AWS SSM Parameter Store as a SecureString for use by the Lambda or other integrations.

## Example Slack Interaction
When a user types `ec2-info` in the Slack channel, Slack sends a POST request to the API Gateway endpoint. The Lambda function responds with:

```
{
  "statusCode": 200,
  "body": "[{\"arn\": \"arn:aws:ec2:ap-southeast-3:*******:instance/i-0b7da2a73a7513aea\", \"public_ip\": \"108.136.168.195\"}, {\"arn\": \"arn:aws:ec2:ap-southeast-3:*******:instance/i-07d943be987768866\", \"public_ip\": \"108.136.43.183\"}]"
}
```

## Infrastructure Components
- **VPC**: With DNS support and hostnames enabled.
- **Public Subnet**: For EC2 instances, with public IP assignment.
- **Internet Gateway & Routing**: For outbound internet access.
- **Security Group**: Allows SSH and HTTP to EC2.
- **EC2 Instances**: Two `t3.2xlarge` Amazon Linux 2 instances in the public subnet.
- **Lambda Function**: Python 3.12, lists running EC2s, censors account ID in ARNs, logs to CloudWatch.
- **IAM Roles & Policies**: For Lambda execution, EC2 describe, and CloudWatch logging.
- **API Gateway (HTTP API)**: POST endpoint integrated with Lambda.
- **SSM Parameter Store**: Secure storage for Slack app credentials.

## How to Deploy
1. Clone this repo and navigate to `simple_chatops_aws_and_slack_integration/`.
2. Ensure your AWS CLI is configured for the Jakarta region.
3. Place your Slack app credentials in `slack_app_credentials.json`.
4. Run:
   ```sh
   terraform init
   terraform apply -auto-approve
   ```
5. Set up your Slack app/webhook to POST to the API Gateway endpoint.

## Customization
- You can modify the Lambda code in `main.tf` to change the response or add more AWS integrations.
- Update security group rules as needed for your use case.

## Clean Up
To destroy all resources:
```sh
tf destroy -auto-approve
```

---

**Enjoy your simple AWS-powered ChatOps with Slack!** 🎉
