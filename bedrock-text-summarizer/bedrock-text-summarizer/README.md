# AWS Bedrock Text Summarization (PDF & Text)

Summarize PDFs (via Textract OCR) or raw text (via HTTP API) using Amazon Bedrock.

## Architecture

```
            +--------------------+
            |  User Uploads PDF  |
            |  s3://<input>/incoming/*  |
            +----------+---------+
                       | S3:ObjectCreated
                       v
                 +-----+------+     StartDocumentTextDetection
                 |  Lambda    |------------------------------+
                 | pdf_ingest |                              |
                 +-----+------+                              |
                       |                                     |
                       | NotificationChannel(RoleArn, SNS)   |
                       v                                     |
                +--------------+     publishes Job status    |
                |   SNS Topic  |-----------------------------+
                +------+-------+                             |
                       |  Subscribed                         |
                       v                                     |
                +--------------+     triggers                |
                |   SQS Queue  |-----------------------------+
                +------+-------+                              v
                       |                                +-----+------+
                       |                                |  Lambda    |
                       |                                | postprocess|
                       |                                +-----+------+
                       |                                      |
                       | GetDocumentTextDetection + Bedrock   |
                       |  (assemble text, summarize)          |
                       |                                      v
                       |                               +------+------------------+
                       |                               |  s3://<output>/summaries/|
                       |                               +--------------------------+
                       |
Raw Text Path:  +--------------------+
 (HTTP API)     |  API Gateway (HTTP)|  POST /summarize  -> Lambda text_summarizer -> Bedrock -> JSON response
                +--------------------+
```

## Components
- **S3 (input/output)** — PDF intake and summary output.
- **Lambda (3)** — `pdf_ingest`, `textract_postprocess`, `text_summarizer`.
- **Textract (Async)** — OCR for PDFs.
- **SNS + SQS** — Job-complete fanout, durable processing.
- **Bedrock (Claude / Llama)** — Summarization.
- **API Gateway** — Text summarization over HTTP.

## Quick Start
1. Install: Terraform >= 1.6, AWS CLI, Python 3.11.
2. `cd terraform && terraform init`
3. `terraform apply -auto-approve`
4. Note outputs for:
   - `input_bucket_name` (upload PDFs under `incoming/`)
   - `output_bucket_name` (summaries under `summaries/`)
   - `api_invoke_url` (POST raw text to `/summarize`).
5. **Enable model access** in the Bedrock console for your chosen region/model.
6. Test:
   - Upload: `aws s3 cp sample.pdf s3://<input>/incoming/sample.pdf`
   - Raw text: `curl -X POST "$API/summarize" -H "content-type: application/json" -d '{"text":"Your text here"}'`

## Security & Compliance
- Buckets are private with SSE-S3.
- Least-privilege IAM for Lambda/Textract publish role.
- Add VPC endpoints/KMS CMKs as needed for stricter environments.

## Costs
Textract (per page), Bedrock tokens, Lambda/SNS/SQS/S3. Clean up with `terraform destroy` when done.
