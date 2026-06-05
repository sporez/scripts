#!/bin/bash

# Test script for web search extension
echo "🔧 Testing Web Search Extension"
echo "================================"
echo ""

# Check if extension exists
if [ -f ~/.pi/agent/extensions/web-search-extension.ts ]; then
    echo "✅ Extension file found"
    echo ""
else
    echo "❌ Extension file not found"
    exit 1
fi

# Check if config exists
if [ -f ~/.pi/agent/config.json ]; then
    echo "✅ Config file found"
    echo ""
else
    echo "❌ Config file not found"
    exit 1
fi

# Check if env file exists
if [ -f ~/.pi/agent/.env ]; then
    echo "✅ Environment file found"
    echo ""
    echo "Environment settings:"
    cat ~/.pi/agent/.env
    echo ""
else
    echo "⚠️  Environment file not found (DuckDuckGo will still work)"
    echo ""
fi

# Try to use the search tool
echo "🧪 Testing search tool..."
pi <<'EOF'
web_search({"query": "TypeScript latest version", "maxResults": 2})
EOF

echo ""
echo "✅ Installation complete!"
echo ""
echo "Usage:"
echo "  - Restart pi to load the extension"
echo "  - Use /search <query> to search"
echo "  - Or let LLM use the web_search tool automatically"