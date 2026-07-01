############################################################
# Terraform: AWS Bedrock FAQ Bot (REST API + Lambda + S3)
############################################################
terraform {
  required_version = ">= 1.6.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.51.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.6.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = ">= 2.4.2"
    }
  }
}

provider "aws" {
  region = var.region
}

locals {
  project          = var.project
  lambda_src_dir   = "${path.module}/../lambda"
  faq_key          = "data/faq.json"
  bedrock_model_id = var.bedrock_model_id
  tags = merge(var.tags, { Project = local.project })
}

resource "random_id" "suffix" {
  byte_length = 3
}

########################
# S3 FAQ bucket (private)
########################
resource "aws_s3_bucket" "faq" {
  bucket = "${local.project}-faq-${random_id.suffix.hex}"
  tags   = local.tags
}

resource "aws_s3_bucket_server_side_encryption_configuration" "faq" {
  bucket = aws_s3_bucket.faq.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "faq" {
  bucket = aws_s3_bucket.faq.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

########################
# IAM for Lambda
########################
data "aws_iam_policy_document" "lambda_assume" {
  statement {
    effect = "Allow"
    principals { type = "Service", identifiers = ["lambda.amazonaws.com"] }
    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "qna" {
  name               = "${local.project}-qna-${random_id.suffix.hex}"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
  tags               = local.tags
}

data "aws_iam_policy_document" "qna_policy_doc" {
  statement {
    effect = "Allow"
    actions = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.faq.arn}/*"]
  }
  statement {
    effect   = "Allow"
    actions  = ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"]
    resources = ["*"]
  }
  statement {
    effect = "Allow"
    actions = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "qna_policy" {
  role   = aws_iam_role.qna.id
  name   = "${local.project}-qna-policy"
  policy = data.aws_iam_policy_document.qna_policy_doc.json
}

########################
# Package & Lambda
########################
data "archive_file" "qna_zip" {
  type        = "zip"
  source_file = "${local.lambda_src_dir}/qna.py"
  output_path = "${path.module}/build/qna.zip"
}

resource "aws_lambda_function" "qna" {
  function_name = "${local.project}-qna"
  role          = aws_iam_role.qna.arn
  runtime       = "python3.11"
  handler       = "qna.lambda_handler"
  filename      = data.archive_file.qna_zip.output_path
  timeout       = 20
  environment {
    variables = {
      FAQ_BUCKET       = aws_s3_bucket.faq.bucket
      FAQ_KEY          = local.faq_key
      BEDROCK_MODEL_ID = local.bedrock_model_id
      MAX_TOKENS       = "600"
      TEMPERATURE      = "0.2"
    }
  }
  tags = local.tags
}

########################
# API Gateway (REST)
########################
resource "aws_api_gateway_rest_api" "api" {
  name        = "${local.project}-api"
  description = "FAQ Bot REST API"
  endpoint_configuration { types = ["EDGE"] }
  tags = local.tags
}

# /ask resource
resource "aws_api_gateway_resource" "ask" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  parent_id   = aws_api_gateway_rest_api.api.root_resource_id
  path_part   = "ask"
}

# POST /ask
resource "aws_api_gateway_method" "ask_post" {
  rest_api_id   = aws_api_gateway_rest_api.api.id
  resource_id   = aws_api_gateway_resource.ask.id
  http_method   = "POST"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "ask_post_integration" {
  rest_api_id             = aws_api_gateway_rest_api.api.id
  resource_id             = aws_api_gateway_resource.ask.id
  http_method             = aws_api_gateway_method.ask_post.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.qna.invoke_arn
}

# OPTIONS /ask for CORS (mock)
resource "aws_api_gateway_method" "ask_options" {
  rest_api_id   = aws_api_gateway_rest_api.api.id
  resource_id   = aws_api_gateway_resource.ask.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "ask_options_integration" {
  rest_api_id          = aws_api_gateway_rest_api.api.id
  resource_id          = aws_api_gateway_resource.ask.id
  http_method          = aws_api_gateway_method.ask_options.http_method
  type                 = "MOCK"
  request_templates    = { "application/json" = "{\"statusCode\": 200}" }
}

resource "aws_api_gateway_method_response" "ask_options_200" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  resource_id = aws_api_gateway_resource.ask.id
  http_method = aws_api_gateway_method.ask_options.http_method
  status_code = "200"
  response_models = { "application/json" = "Empty" }
  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = true,
    "method.response.header.Access-Control-Allow-Methods" = true,
    "method.response.header.Access-Control-Allow-Origin"  = true
  }
}

resource "aws_api_gateway_integration_response" "ask_options_200" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  resource_id = aws_api_gateway_resource.ask.id
  http_method = aws_api_gateway_method.ask_options.http_method
  status_code = aws_api_gateway_method_response.ask_options_200.status_code
  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = "'Content-Type,Authorization'",
    "method.response.header.Access-Control-Allow-Methods" = "'OPTIONS,POST,GET'",
    "method.response.header.Access-Control-Allow-Origin"  = "'*'"
  }
  response_templates = { "application/json" = "" }
  depends_on = [aws_api_gateway_integration.ask_options_integration]
}

# GET /health
resource "aws_api_gateway_resource" "health" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  parent_id   = aws_api_gateway_rest_api.api.root_resource_id
  path_part   = "health"
}

resource "aws_api_gateway_method" "health_get" {
  rest_api_id   = aws_api_gateway_rest_api.api.id
  resource_id   = aws_api_gateway_resource.health.id
  http_method   = "GET"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "health_get_integration" {
  rest_api_id             = aws_api_gateway_rest_api.api.id
  resource_id             = aws_api_gateway_resource.health.id
  http_method             = aws_api_gateway_method.health_get.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.qna.invoke_arn
}

# Allow API Gateway to invoke Lambda
resource "aws_lambda_permission" "apigw_invoke" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.qna.arn
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.api.execution_arn}/*/*"
}

# Deployment & stage
resource "aws_api_gateway_deployment" "deployment" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  triggers = {
    redeploy = sha1(join(",", [
      aws_api_gateway_integration.ask_post_integration.id,
      aws_api_gateway_integration.ask_options_integration.id,
      aws_api_gateway_integration.health_get_integration.id
    ]))
  }
  depends_on = [
    aws_api_gateway_integration.ask_post_integration,
    aws_api_gateway_integration.ask_options_integration,
    aws_api_gateway_integration.health_get_integration
  ]
}

resource "aws_api_gateway_stage" "prod" {
  rest_api_id   = aws_api_gateway_rest_api.api.id
  stage_name    = "prod"
  deployment_id = aws_api_gateway_deployment.deployment.id
  tags          = local.tags
}

########################
# Outputs
########################
output "faq_bucket_name" {
  value       = aws_s3_bucket.faq.bucket
  description = "Upload your FAQ JSON to s3://<bucket>/data/faq.json"
}

output "api_invoke_url" {
  value       = "${aws_api_gateway_rest_api.api.execution_arn}"
  description = "Execution ARN (use https URL below)"
}

output "api_base_url" {
  value       = "https://${aws_api_gateway_rest_api.api.id}.execute-api.${var.region}.amazonaws.com/${aws_api_gateway_stage.prod.stage_name}"
  description = "Base URL like https://xxxx.execute-api.<region>.amazonaws.com/prod"
}
