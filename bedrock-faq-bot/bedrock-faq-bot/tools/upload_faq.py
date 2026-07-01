"""
Helper: Upload the local data/faq.json to your Terraform-created S3 bucket.
Usage:
  python tools/upload_faq.py --bucket <bucket-name> [--key data/faq.json]
"""
import argparse, json, boto3, os, sys

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bucket", required=True, help="FAQ S3 bucket name")
    ap.add_argument("--key", default="data/faq.json", help="Object key")
    ap.add_argument("--file", default="../data/faq.json", help="Local path to FAQ JSON")
    args = ap.parse_args()

    s3 = boto3.client("s3")
    s3.upload_file(args.file, args.bucket, args.key)
    print(f"Uploaded {args.file} -> s3://{args.bucket}/{args.key}")

if __name__ == "__main__":
    main()
