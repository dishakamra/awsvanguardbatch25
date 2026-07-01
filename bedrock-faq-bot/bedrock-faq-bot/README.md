# AWS Bedrock FAQ Bot (Claude/Titan/Llama via Bedrock)

Answer customer FAQs using your curated FAQ file as context.

## Architecture

```
+--------------------+           +----------------------+
|  FAQ JSON in S3    |<----------|  Upload (one-time)   |
|  s3://<faq-bucket>/|           +----------+-----------+
|  data/faq.json     |                      |
+---------+----------+                      |
          | (read at cold start / refresh)  |
          v                                  v
     +----+----------------------------------+------------------+
     |                     AWS Lambda (qna_bot)                 |
     | 1) Load FAQs from S3 (cache in memory)                   |
     | 2) Retrieve top-K relevant Q&As (simple similarity)      |
     | 3) Prompt Amazon Bedrock (Claude/Titan/Llama)            |
     | 4) Return answer + cited FAQ matches                     |
     +----+--------------+---------------------------+----------+
                          ^                           |
                          |  Lambda Proxy Integration |
                    +-----+-----+                     |
                    | API GW    |  POST /ask          |
                    |  (REST)   |  GET  /health       |
                    +-----+-----+                     |
                          ^                           |
                          |  HTTPS                    |
                    +-----+---------------------------+
                    |  Browser Frontend (HTML/JS)    |
                    |  Simple chat UI calls API      |
                    +--------------------------------+
```

## Quick Start

1) **Prepare FAQ data**  
   - Edit `data/faq.json` (sample included). Format: list of `{ "question": "...", "answer": "..." }`.

2) **Deploy infrastructure**  
```bash
cd terraform
terraform init
terraform apply -auto-approve
```
Outputs:
- `faq_bucket_name` — put your `faq.json` here under `data/faq.json`.
- `api_invoke_url` — base URL for API (append `/prod/ask`).

3) **Upload FAQ file**
```bash
aws s3 cp ../data/faq.json s3://<faq_bucket_name>/data/faq.json
```

4) **Test API**
```bash
curl -s -X POST "$API/prod/ask"   -H "content-type: application/json"   -d '{"question":"What is the return policy?"}' | jq
```

5) **Run frontend (local)**  
Open `web/index.html` in a browser. In the top-right, paste your **API base** (e.g., `https://xxxx.execute-api.ap-south-1.amazonaws.com/prod`) and ask away.

## Notes
- Default model: `anthropic.claude-3-sonnet-20240229-v1:0`. You can change with `-var bedrock_model_id=...`.
- Lambda returns CORS headers; REST API also has an `OPTIONS /ask` method for preflight.
- For large or open-ended KBs, add retrieval with vector search (e.g., Titan Embeddings + OpenSearch/Kendra). This starter keeps it lightweight.

## Clean up
```bash
terraform destroy
```
