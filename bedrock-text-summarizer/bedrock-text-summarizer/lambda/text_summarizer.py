import json, os, logging, boto3
from botocore.config import Config

logger = logging.getLogger()
logger.setLevel(logging.INFO)

region = os.environ.get("AWS_REGION", "us-east-1")
bedrock_runtime = boto3.client("bedrock-runtime", region_name=region, config=Config(retries={"max_attempts": 3}))

BEDROCK_MODEL_ID = os.environ.get("BEDROCK_MODEL_ID", "anthropic.claude-3-sonnet-20240229-v1:0")
SUMMARIZE_MAX_TOKENS = int(os.environ.get("SUMMARIZE_MAX_TOKENS", "1024"))

def _summarize(text: str) -> str:
    prompt = f"Summarize the following text into bullet points and one concluding paragraph. Be faithful to the source.\n\nText:\n{text[:20000]}"
    body = {
        "anthropic_version": "bedrock-2023-05-31",
        "messages": [{"role": "user", "content": [{"type": "text", "text": prompt}]}],
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
    parts = payload.get("content", [])
    if parts and isinstance(parts, list) and parts[0].get("type") == "text":
        return parts[0].get("text", "").strip()
    return payload.get("outputText") or payload.get("generated_text") or json.dumps(payload)

def lambda_handler(event, context):
    # HTTP API (payload v2.0)
    body = {}
    if "body" in event and event["body"]:
        body = json.loads(event["body"])
    elif isinstance(event, dict):
        body = event
    text = body.get("text", "")
    if not text:
        return {"statusCode": 400, "headers": {"content-type": "application/json"}, "body": json.dumps({"error":"Missing 'text' in body"})}

    summary = _summarize(text)
    return {
        "statusCode": 200,
        "headers": {"content-type": "application/json"},
        "body": json.dumps({"summary": summary})
    }
