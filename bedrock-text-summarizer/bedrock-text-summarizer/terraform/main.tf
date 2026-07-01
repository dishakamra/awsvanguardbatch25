############################################################
# Terraform: AWS Bedrock + Textract Summarizer (PDF & Text)
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
  project              = var.project
  input_prefix         = "incoming/"
  summaries_prefix     = "summaries/"
  extracted_prefix     = "extracted/"
  lambda_src_dir       = "${path.module}/../lambda"
  bedrock_model_id     = var.bedrock_model_id
  tags = merge(var.tags, {
    Project = local.project
  })
}

data "aws_caller_identity" "current" {}

resource "random_id" "suffix" {
  byte_length = 3
}

########################
# S3 Buckets
########################
resource "aws_s3_bucket" "input" {
  bucket = "${local.project}-input-${random_id.suffix.hex}"
  tags   = local.tags
}

resource "aws_s3_bucket_server_side_encryption_configuration" "input" {
  bucket = aws_s3_bucket.input.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "input" {
  bucket = aws_s3_bucket.input.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket" "output" {
  bucket = "${local.project}-output-${random_id.suffix.hex}"
  tags   = local.tags
}

resource "aws_s3_bucket_server_side_encryption_configuration" "output" {
  bucket = aws_s3_bucket.output.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "output" {
  bucket = aws_s3_bucket.output.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

########################
# SNS + SQS for Textract completion
########################
resource "aws_sns_topic" "textract_complete" {
  name = "${local.project}-textract-complete"
  tags = local.tags
}

resource "aws_sqs_queue" "textract_complete" {
  name                      = "${local.project}-textract-complete-${random_id.suffix.hex}"
  visibility_timeout_seconds = 300
  message_retention_seconds  = 86400
  tags                      = local.tags
}

# Allow SNS to publish to SQS
data "aws_iam_policy_document" "sqs_policy" {
  statement {
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["sns.amazonaws.com"]
    }
    actions = [
      "sqs:SendMessage",
      "sqs:SendMessageBatch",
      "sqs:GetQueueAttributes",
      "sqs:GetQueueUrl"
    ]
    resources = [aws_sqs_queue.textract_complete.arn]

    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [aws_sns_topic.textract_complete.arn]
    }
  }
}

resource "aws_sqs_queue_policy" "sns_to_sqs" {
  queue_url = aws_sqs_queue.textract_complete.id
  policy    = data.aws_iam_policy_document.sqs_policy.json
}

resource "aws_sns_topic_subscription" "sns_to_sqs" {
  topic_arn = aws_sns_topic.textract_complete.arn
  protocol  = "sqs"
  endpoint  = aws_sqs_queue.textract_complete.arn

  # Raw message delivery: SQS receives the Textract JSON directly as body.
  raw_message_delivery = true
}

########################
# IAM Roles
########################

# Role that Textract uses to publish job completion to SNS
data "aws_iam_policy_document" "textract_sns_assume" {
  statement {
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["textract.amazonaws.com"]
    }
    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "textract_publish_role" {
  name               = "${local.project}-textract-publish-role-${random_id.suffix.hex}"
  assume_role_policy = data.aws_iam_policy_document.textract_sns_assume.json
  tags               = local.tags
}

data "aws_iam_policy_document" "textract_publish_policy" {
  statement {
    effect = "Allow"
    actions = ["sns:Publish"]
    resources = [aws_sns_topic.textract_complete.arn]
  }
}

resource "aws_iam_role_policy" "textract_publish_policy" {
  name   = "${local.project}-textract-publish"
  role   = aws_iam_role.textract_publish_role.id
  policy = data.aws_iam_policy_document.textract_publish_policy.json
}

# Lambda execution roles

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
    actions = ["sts:AssumeRole"]
  }
}

# pdf_ingest role
resource "aws_iam_role" "pdf_ingest" {
  name               = "${local.project}-pdf-ingest-${random_id.suffix.hex}"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
  tags               = local.tags
}

data "aws_iam_policy_document" "pdf_ingest_policy" {
  statement {
    effect = "Allow"
    actions = [
      "s3:GetObject"
    ]
    resources = ["${aws_s3_bucket.input.arn}/*"]
  }
  statement {
    effect = "Allow"
    actions = [
      "textract:StartDocumentTextDetection"
    ]
    resources = ["*"]
  }
  # Allow passing the Textract publish role for NotificationChannel
  statement {
    effect = "Allow"
    actions = ["iam:PassRole"]
    resources = [aws_iam_role.textract_publish_role.arn]
    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["textract.amazonaws.com"]
    }
  }
  # Logs
  statement {
    effect = "Allow"
    actions = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "pdf_ingest_policy" {
  name   = "${local.project}-pdf-ingest-policy"
  role   = aws_iam_role.pdf_ingest.id
  policy = data.aws_iam_policy_document.pdf_ingest_policy.json
}

# textract_postprocess role
resource "aws_iam_role" "postprocess" {
  name               = "${local.project}-postprocess-${random_id.suffix.hex}"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
  tags               = local.tags
}

data "aws_iam_policy_document" "postprocess_policy" {
  statement {
    effect = "Allow"
    actions = [
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
      "sqs:GetQueueAttributes"
    ]
    resources = [aws_sqs_queue.textract_complete.arn]
  }
  statement {
    effect = "Allow"
    actions = [
      "textract:GetDocumentTextDetection"
    ]
    resources = ["*"]
  }
  statement {
    effect = "Allow"
    actions = [
      "s3:GetObject"
    ]
    resources = ["${aws_s3_bucket.input.arn}/*"]
  }
  statement {
    effect = "Allow"
    actions = [
      "s3:PutObject"
    ]
    resources = ["${aws_s3_bucket.output.arn}/*"]
  }
  statement {
    effect = "Allow"
    actions = [
      "bedrock:InvokeModel",
      "bedrock:InvokeModelWithResponseStream"
    ]
    resources = ["*"]
  }
  # Logs
  statement {
    effect = "Allow"
    actions = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "postprocess_policy" {
  name   = "${local.project}-postprocess-policy"
  role   = aws_iam_role.postprocess.id
  policy = data.aws_iam_policy_document.postprocess_policy.json
}

# text_summarizer role
resource "aws_iam_role" "text_summarizer" {
  name               = "${local.project}-text-summarizer-${random_id.suffix.hex}"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
  tags               = local.tags
}

data "aws_iam_policy_document" "text_summarizer_policy" {
  statement {
    effect = "Allow"
    actions = [
      "bedrock:InvokeModel",
      "bedrock:InvokeModelWithResponseStream"
    ]
    resources = ["*"]
  }
  # Logs
  statement {
    effect = "Allow"
    actions = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "text_summarizer_policy" {
  name   = "${local.project}-text-summarizer-policy"
  role   = aws_iam_role.text_summarizer.id
  policy = data.aws_iam_policy_document.text_summarizer_policy.json
}

########################
# Lambda Packages
########################
data "archive_file" "pdf_ingest_zip" {
  type        = "zip"
  source_file = "${local.lambda_src_dir}/pdf_ingest.py"
  output_path = "${path.module}/build/pdf_ingest.zip"
}

data "archive_file" "postprocess_zip" {
  type        = "zip"
  source_file = "${local.lambda_src_dir}/textract_postprocess.py"
  output_path = "${path.module}/build/textract_postprocess.zip"
}

data "archive_file" "text_summarizer_zip" {
  type        = "zip"
  source_file = "${local.lambda_src_dir}/text_summarizer.py"
  output_path = "${path.module}/build/text_summarizer.zip"
}

resource "aws_lambda_function" "pdf_ingest" {
  function_name = "${local.project}-pdf-ingest"
  role          = aws_iam_role.pdf_ingest.arn
  runtime       = "python3.11"
  handler       = "pdf_ingest.lambda_handler"
  filename      = data.archive_file.pdf_ingest_zip.output_path
  timeout       = 60
  environment {
    variables = {
      SNS_TOPIC_ARN      = aws_sns_topic.textract_complete.arn
      TEXTRACT_ROLE_ARN  = aws_iam_role.textract_publish_role.arn
      INPUT_BUCKET       = aws_s3_bucket.input.bucket
    }
  }
  tags = local.tags
}

resource "aws_lambda_function" "postprocess" {
  function_name = "${local.project}-postprocess"
  role          = aws_iam_role.postprocess.arn
  runtime       = "python3.11"
  handler       = "textract_postprocess.lambda_handler"
  filename      = data.archive_file.postprocess_zip.output_path
  timeout       = 900
  environment {
    variables = {
      OUTPUT_BUCKET    = aws_s3_bucket.output.bucket
      INPUT_BUCKET     = aws_s3_bucket.input.bucket
      BEDROCK_MODEL_ID = local.bedrock_model_id
      SUMMARIZE_MAX_TOKENS = "1024"
    }
  }
  tags = local.tags
}

resource "aws_lambda_function" "text_summarizer" {
  function_name = "${local.project}-text-summarizer"
  role          = aws_iam_role.text_summarizer.arn
  runtime       = "python3.11"
  handler       = "text_summarizer.lambda_handler"
  filename      = data.archive_file.text_summarizer_zip.output_path
  timeout       = 60
  environment {
    variables = {
      BEDROCK_MODEL_ID = local.bedrock_model_id
      SUMMARIZE_MAX_TOKENS = "1024"
    }
  }
  tags = local.tags
}

########################
# Eventing
########################

# S3 -> Lambda (ingest on new PDFs)
resource "aws_lambda_permission" "allow_s3_invoke" {
  statement_id  = "AllowExecutionFromS3"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.pdf_ingest.function_name
  principal     = "s3.amazonaws.com"
  source_arn    = aws_s3_bucket.input.arn
}

resource "aws_s3_bucket_notification" "input_notifications" {
  bucket = aws_s3_bucket.input.id

  lambda_function {
    lambda_function_arn = aws_lambda_function.pdf_ingest.arn
    events              = ["s3:ObjectCreated:*"]
    filter_prefix       = local.input_prefix
    filter_suffix       = ".pdf"
  }

  depends_on = [aws_lambda_permission.allow_s3_invoke]
}

# SQS -> Lambda (postprocess)
resource "aws_lambda_event_source_mapping" "sqs_to_postprocess" {
  event_source_arn = aws_sqs_queue.textract_complete.arn
  function_name    = aws_lambda_function.postprocess.arn
  batch_size       = 5
  enabled          = true
}

########################
# API Gateway (HTTP API) -> text_summarizer
########################

resource "aws_apigatewayv2_api" "http" {
  name          = "${local.project}-api"
  protocol_type = "HTTP"
  tags          = local.tags
}

resource "aws_apigatewayv2_integration" "summarize_integration" {
  api_id                 = aws_apigatewayv2_api.http.id
  integration_type       = "AWS_PROXY"
  integration_method     = "POST"
  payload_format_version = "2.0"
  integration_uri        = aws_lambda_function.text_summarizer.invoke_arn
}

resource "aws_apigatewayv2_route" "summarize_route" {
  api_id    = aws_apigatewayv2_api.http.id
  route_key = "POST /summarize"
  target    = "integrations/${aws_apigatewayv2_integration.summarize_integration.id}"
}

resource "aws_lambda_permission" "allow_apigw" {
  statement_id  = "AllowAPIGwInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.text_summarizer.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.http.execution_arn}/*/*"
}

resource "aws_apigatewayv2_stage" "prod" {
  api_id      = aws_apigatewayv2_api.http.id
  name        = "prod"
  auto_deploy = true
  tags        = local.tags
}

########################
# Outputs
########################

output "input_bucket_name" {
  value       = aws_s3_bucket.input.bucket
  description = "Upload PDFs under s3://<bucket>/incoming/*.pdf"
}

output "output_bucket_name" {
  value       = aws_s3_bucket.output.bucket
  description = "Summaries written to s3://<bucket>/summaries/"
}

output "api_invoke_url" {
  value       = "${aws_apigatewayv2_api.http.api_endpoint}/${aws_apigatewayv2_stage.prod.name}"
  description = "HTTP API base URL"
}
