#!/bin/bash

# ============================================================================
# Apply Database Triggers
# ============================================================================
# This script applies custom triggers to your Supabase database
# Run this after making changes to trigger files
# ============================================================================

set -e  # Exit on error

echo "🔧 Applying database triggers..."

# Check if Supabase is running
if ! curl -s http://127.0.0.1:54321/rest/v1/ > /dev/null 2>&1; then
  echo "❌ Supabase is not running. Start it with: supabase start"
  exit 1
fi

# Apply trigger using Docker exec
echo "📝 Applying handle_user_registration trigger..."
docker exec -i supabase_db_mobi-pass-be psql -U postgres postgres < database/triggers/handle_user_registration.sql

echo "✅ Triggers applied successfully!"
echo ""
echo "💡 You can now test the register endpoint:"
echo "   curl -v -X POST http://127.0.0.1:54321/functions/v1/register \\"
echo "     -H 'Content-Type: application/json' \\"
echo "     -d '{\"email\":\"someonestolemyyahoo@gmail.com\"}'"

