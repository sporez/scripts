# Web Search Extension - Installation Complete ✅

## What's Been Installed

**Location:** `~/.pi/agent/extensions/web-search-extension.ts`

**Configuration:** `~/.pi/agent/config.json`
- Provider: DuckDuckGo (no API key required)
- Default model: lmstudio/glm-4.7-flash

**Environment:** `~/.pi/agent/.env`
- WEB_SEARCH_PROVIDER=duckduckgo

## How to Use

### Option 1: Let Pi Automatically Use Web Search
Just start a conversation:

```
pi
> Search for the latest TypeScript version
> Find information about React 18 features
> What is quantum computing?
```

### Option 2: Use the `/search` Command
```
pi
> /search how to use web search extension
```

### Option 3: Use the Tool Directly
```
pi
> web_search with query "TypeScript latest version"
```

## Testing the Extension

Run the test script:
```bash
/home/neil/apps/scripts/test-search.sh
```

## Troubleshooting

If web search doesn't seem to be working, try these steps:

1. **Restart pi:**
   ```bash
   exit  # Exit current pi session
   pi    # Start fresh
   ```

2. **Check the extension loaded:**
   ```bash
   grep -i web_search ~/.pi/agent/extensions/web-search-extension.ts | head -5
   ```

3. **Verify config:**
   ```bash
   cat ~/.pi/agent/config.json
   ```

4. **Check environment:**
   ```bash
   cat ~/.pi/agent/.env
   ```

## Search Providers Available

The extension supports 3 providers:

1. **DuckDuckGo** (currently active) - No API key needed
2. **Bing** - Requires API key from Azure
3. **Custom** - Use your own API endpoint

To switch providers, edit `~/.pi/agent/.env`:
```bash
echo "WEB_SEARCH_PROVIDER=bing" >> ~/.pi/agent/.env
```

## Files Created

```
~/.pi/agent/
├── extensions/
│   └── web-search-extension.ts    (8.8 KB)
├── config.json                     (main config)
└── .env                           (environment settings)

/home/neil/apps/scripts/
├── test-search.sh                 (test script)
└── INSTALLATION.md                (this file)
```

## Next Steps

1. Start a new pi session
2. Try a web search query
3. Let me know if you need help or want to switch providers!

Happy searching! 🔍