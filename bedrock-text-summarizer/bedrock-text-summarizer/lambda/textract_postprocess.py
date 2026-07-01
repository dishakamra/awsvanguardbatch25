import json, os, logging, boto3, time
from botocore.config import Config

logger = logging.getLogger()
logger.setLevel(logging.INFO)

s3 = boto3.client("s3")
textract = boto3.client("textract")

region = os.environ.get("AWS_REGION", "us-east-1")
bedrock_runtime = boto3.client("bedrock-runtime", region_name=region, config=Config(retries={"max_attempts": 3}))

OUTPUT_BUCKET = os.environ["OUTPUT_BUCKET"]
INPUT_BUCKET = os.environ["INPUT_BUCKET"]
BEDROCK_MODEL_ID = os.environ.get("BEDROCK_MODEL_ID", "anthropic.claude-3-sonnet-20240229-v1:0")
SUMMARIZE_MAX_TOKENS = int(os.environ.get("SUMMARIZE_MAX_TOKENS", "1024"))

def _get_textract_text(job_id: str) -> str:
    """Paginate over GetDocumentTextDetection and assemble lines into text."""
    next_token = None
    all_lines = []
    while True:
        if next_token:
            resp = textract.get_document_text_detection(JobId=job_id, NextToken=next_token)
        else:
            resp = textract.get_document_text_detection(JobId=job_id)
        for block in resp.get("Blocks", []):
            if block.get("BlockType") == "LINE":
                all_lines.append(block.get("Text", ""))
        next_token = resp.get("NextToken")
        if not next_token:
            break
    return "\n".join(all_lines)

def _summarize_with_bedrock(text: str) -> str:
    """Use Anthropic Claude Messages API via Bedrock to summarize text."""
    prompt = f"Summarize the following document into concise bullet points followed by a short paragraph. Keep legal/meeting names accurate.\n\nDocument:\n{text[:20000]}"
    body = {
        "anthropic_version": "bedrock-2023-05-31",
        "messages": [
            {"role": "user", "content": [{"type": "text", "text": prompt}]}
        ],
        "max_tokens": SUMMARIZE_MAX_TOKENS,
        "temperature": 0.2
    }
    resp = bedrock_runtime.invoke_model(
        modelId=BEDROCK_MODEL_ID,
        body=json.dumps(body).encode("utf-8"),
        contentType="application/json",
        accept="application/json",
    )
    payload = json.loads(resp["body"].read())
    # Anthropic message response shape
    parts = payload.get("content", [])
    if parts and isinstance(parts, list) and parts[0].get("type") == "text":
        return parts[0].get("text", "").strip()
    # Fallback for other models (e.g., Titan Text)
    return payload.get("outputText") or payload.get("generated_text") or json.dumps(payload)

def lambda_handler(event, context):
    logger.info("SQS Event: %s", json.dumps(event))
    results = []
    for record in event.get("Records", []):
        # We enabled raw_message_delivery in SNS->SQS, so Body is the Textract JSON string
        message = json.loads(record["body"])
        status = message.get("Status")
        job_id = message.get("JobId")
        job_tag = message.get("JobTag")  # original S3 key
        doc_loc = message.get("DocumentLocation", {}).get("S3ObjectName", job_tag)

        if status != "SUCCEEDED":
            logger.warning("Textract job %s not successful (Status=%s)", job_id, status)
            continue

        # 1) Fetch text from Textract
        text = _get_textract_text(job_id)

        # 2) Summarize via Bedrock
        summary = _summarize_with_bedrock(text)

        # 3) Write outputs to S3
        base = (doc_loc or job_tag or f"job-{job_id}").rsplit("/", 1)[-1].rsplit(".", 1)[0]
        summary_key = f"summaries/{base}.summary.txt"
        raw_key = f"extracted/{base}.txt"

        s3.put_object(Bucket=OUTPUT_BUCKET, Key=summary_key, Body=summary.encode("utf-8"))
        s3.put_object(Bucket=OUTPUT_BUCKET, Key=raw_key, Body=text.encode("utf-8"))

        results.append({"job_id": job_id, "summary_key": summary_key, "raw_key": raw_key})

    return {"statusCode": 200, "body": json.dumps({"results": results})}
