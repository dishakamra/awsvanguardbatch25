import json, os, logging, boto3, re, string
from botocore.config import Config

logger = logging.getLogger()
logger.setLevel(logging.INFO)

region = os.environ.get("AWS_REGION", "us-east-1")
s3 = boto3.client("s3", region_name=region)
bedrock = boto3.client("bedrock-runtime", region_name=region, config=Config(retries={"max_attempts": 3}))

FAQ_BUCKET = os.environ["FAQ_BUCKET"]
FAQ_KEY = os.environ.get("FAQ_KEY", "data/faq.json")
BEDROCK_MODEL_ID = os.environ.get("BEDROCK_MODEL_ID", "anthropic.claude-3-sonnet-20240229-v1:0")
MAX_TOKENS = int(os.environ.get("MAX_TOKENS", "600"))
TEMPERATURE = float(os.environ.get("TEMPERATURE", "0.2"))

_FAQ_CACHE = None

def _normalize(text: str):
    text = text.lower()
    text = re.sub(r"[^a-z0-9\s]", " ", text)
    tokens = [t for t in text.split() if t]
    return set(tokens)

def _load_faqs():
    global _FAQ_CACHE
    if _FAQ_CACHE is not None:
        return _FAQ_CACHE
    resp = s3.get_object(Bucket=FAQ_BUCKET, Key=FAQ_KEY)
    body = resp["Body"].read()
    faqs = json.loads(body.decode("utf-8"))
    # precompute tokens for quick scoring
    for item in faqs:
        item["_q_tokens"] = _normalize(item.get("question", ""))
        item["_a_tokens"] = _normalize(item.get("answer", ""))
    _FAQ_CACHE = faqs
    logger.info("Loaded %d FAQ entries", len(faqs))
    return _FAQ_CACHE

def _score(query_tokens, item):
    # Jaccard on Q, light weight overlap on A, plus substring bonus
    q_overlap = len(query_tokens & item["_q_tokens"])
    q_union = len(query_tokens | item["_q_tokens"]) or 1
    jaccard_q = q_overlap / q_union

    a_overlap = len(query_tokens & item["_a_tokens"])
    a_union = len(query_tokens | item["_a_tokens"]) or 1
    jaccard_a = a_overlap / a_union

    # substring bonus if any query word appears as substring in question
    substr = 0.0
    for tk in query_tokens:
        for qt in item["_q_tokens"]:
            if tk in qt:
                substr = 0.1
                break
        if substr > 0:
            break

    return 0.7 * jaccard_q + 0.2 * jaccard_a + substr

def _retrieve(faqs, question, k=5):
    q_tokens = _normalize(question)
    ranked = sorted(faqs, key=lambda it: _score(q_tokens, it), reverse=True)
    return ranked[:k]

def _build_prompt(question: str, top_items):
    context_lines = []
    for idx, it in enumerate(top_items, 1):
        q = it.get("question", "").strip()
        a = it.get("answer", "").strip()
        context_lines.append(f"{idx}. Q: {q}\n   A: {a}")
    context = "\n".join(context_lines) if context_lines else "No FAQ items were retrieved."

    system_rules = (
        "You are a helpful FAQ assistant for a company.\n"
        "- Use ONLY the provided FAQ context to answer.\n"
        "- If the context doesn't contain the answer, say you don't know and suggest contacting support.\n"
        "- Keep responses concise, with short bullet points when helpful.\n"
    )

    user_msg = (
        f"FAQ context:\n{context}\n\n"
        f"User question: {question}\n\n"
        "Answer using information from the context. If insufficient, say you don't know."
    )

    body = {
        "anthropic_version": "bedrock-2023-05-31",
        "messages": [
            {"role":"user","content":[{"type":"text","text": system_rules + "\n\n" + user_msg}]}
        ],
        "max_tokens": MAX_TOKENS,
        "temperature": TEMPERATURE
    }
    return body

def _ask_bedrock(body):
    resp = bedrock.invoke_model(
        modelId=BEDROCK_MODEL_ID,
        body=json.dumps(body).encode("utf-8"),
        contentType="application/json",
        accept="application/json",
    )
    payload = json.loads(resp["body"].read())
    parts = payload.get("content", [])
    if parts and isinstance(parts, list) and parts[0].get("type") == "text":
        return parts[0]["text"].strip()
    # Fallback shapes for other providers
    return payload.get("outputText") or payload.get("generated_text") or json.dumps(payload)

def _resp(status, body):
    return {
        "statusCode": status,
        "headers": {
            "content-type": "application/json",
            "Access-Control-Allow-Origin": "*",
            "Access-Control-Allow-Headers": "Content-Type,Authorization",
            "Access-Control-Allow-Methods": "OPTIONS,POST,GET"
        },
        "body": json.dumps(body)
    }

def lambda_handler(event, context):
    method = event.get("httpMethod", "GET")
    path = event.get("path", "/")
    if method == "OPTIONS":
        return _resp(200, {"ok": True})

    if method == "GET" and (path.endswith("/health") or path == "/health"):
        return _resp(200, {"ok": True, "service": "faq-bot"})

    if method == "POST":
        body_raw = event.get("body") or "{}"
        try:
            data = json.loads(body_raw)
        except Exception:
            return _resp(400, {"error":"Invalid JSON"})
        question = (data.get("question") or "").strip()
        if not question:
            return _resp(400, {"error":"Missing 'question' in body"})
        faqs = _load_faqs()
        top = _retrieve(faqs, question, k=5)
        bedrock_body = _build_prompt(question, top)
        answer = _ask_bedrock(bedrock_body)

        sources = [{"question": t.get("question"), "answer": t.get("answer")} for t in top]
        return _resp(200, {"answer": answer, "sources": sources})

    return _resp(404, {"error":"Not found"})
