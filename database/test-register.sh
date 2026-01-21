#!/bin/bash

# ============================================================================
# Test Register Endpoint
# ============================================================================
# Quick script to test the register endpoint with proper error checking
# ============================================================================

set -e

EMAIL="${1:-someonestolemyyahoo@gmail.com}"

echo "🧪 Testing register endpoint with email: $EMAIL"
echo ""

# Test the endpoint
RESPONSE=$(curl -s -w "\nHTTP_STATUS:%{http_code}" \
  -X POST http://127.0.0.1:54321/functions/v1/register \
  -H 'Content-Type: application/json' \
  -d "{\"email\":\"$EMAIL\"}")

# Extract body and status
HTTP_BODY=$(echo "$RESPONSE" | sed -e 's/HTTP_STATUS\:.*//g')
HTTP_STATUS=$(echo "$RESPONSE" | tr -d '\n' | sed -e 's/.*HTTP_STATUS://')

echo "Response Status: $HTTP_STATUS"
echo "Response Body:"
echo "$HTTP_BODY" | jq '.' 2>/dev/null || echo "$HTTP_BODY"
echo ""

if [ "$HTTP_STATUS" -eq 200 ]; then
  echo "✅ Success! Check Inbucket for the OTP email:"
  echo "   http://127.0.0.1:54324"
else
  echo "❌ Failed with status $HTTP_STATUS"
  exit 1
fi

