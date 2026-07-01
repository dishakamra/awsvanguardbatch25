##############################
# Variables
##############################
variable "region" {
  description = "AWS region (ensure Bedrock/Textract support)"
  type        = string
  default     = "ap-south-1"
}

variable "project" {
  description = "Name prefix for resources"
  type        = string
  default     = "bedrock-summarizer"
}

# Choose a model available in your Region.
# Good defaults: Claude 3 Sonnet (widely supported) or Claude 3.5 Haiku/Sonnet (if enabled)
variable "bedrock_model_id" {
  description = "Amazon Bedrock model ID"
  type        = string
  default     = "anthropic.claude-3-sonnet-20240229-v1:0"
}

variable "tags" {
  description = "Common tags"
  type        = map(string)
  default     = {
    Owner = "Team-Apps"
  }
}
