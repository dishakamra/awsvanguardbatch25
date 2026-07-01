import json, os, logging, boto3, urllib.parse

logger = logging.getLogger()
logger.setLevel(logging.INFO)

s3 = boto3.client("s3")
textract = boto3.client("textract")

SNS_TOPIC_ARN = os.environ["SNS_TOPIC_ARN"]
TEXTRACT_ROLE_ARN = os.environ["TEXTRACT_ROLE_ARN"]
INPUT_BUCKET = os.environ["INPUT_BUCKET"]

def lambda_handler(event, context):
    # Triggered by S3:ObjectCreated event
    logger.info("Event: %s", json.dumps(event))
    for rec in event.get("Records", []):
        bucket = rec["s3"]["bucket"]["name"]
        key = urllib.parse.unquote_plus(rec["s3"]["object"]["key"])
        if not key.lower().endswith(".pdf"):
            logger.info("Skipping non-PDF key: %s", key)
            continue

        # Start async text detection for PDFs
        resp = textract.start_document_text_detection(
            DocumentLocation={
                "S3Object": {"Bucket": bucket, "Name": key}
            },
            NotificationChannel={
                "SNSTopicArn": SNS_TOPIC_ARN,
                "RoleArn": TEXTRACT_ROLE_ARN,
            },
            JobTag=key  # so downstream knows which object
        )
        logger.info("Started Textract JobId=%s for %s", resp["JobId"], key)

    return {"statusCode": 200, "body": json.dumps({"ok": True})}
