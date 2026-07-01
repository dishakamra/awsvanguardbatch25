##############################
# Variables
##############################
variable "region" {
  description = "AWS region (ensure Bedrock supports desired model)"
  type        = string
  default     = "ap-south-1"
}

variable "project" {
  description = "Name prefix for resources"
  type        = string
  default     = "bedrock-faq-bot"
}

variable "bedrock_model_id" {
  description = "Amazon Bedrock model ID (Claude/Titan/Llama)"
  type        = string
  default     = "anthropic.claude-3-sonnet-20240229-v1:0"
}

variable "tags" {
  description = "Common tags"
  type        = map(string)
  default     = { Owner = "Team-Apps" }
}
