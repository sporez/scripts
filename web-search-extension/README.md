# Web Search Extension for Pi

A web search extension that provides real-time web search capabilities within the pi coding agent.

## Features

- 🔍 **Multiple Search Providers**: Bing, DuckDuckGo, or custom API endpoints
- 🚫 **No API Required**: DuckDuckGo mode works without any setup
- 📊 **Structured Results**: Clean, formatted search results with titles, URLs, and snippets
- ⏸️ **Cancellation Support**: Respects abort signals for user cancellation
- 📈 **Progress Updates**: Shows search progress during execution
- 🧠 **Smart Prompting**: Includes guidelines for when and how to use web search

## Installation

### Option 1: Copy the Extension

Simply copy `web-search-extension.ts` to your pi extensions directory:

```bash
cp web-search-extension.ts ~/.pi/extensions/
```

Then create a `web-search-pi.json` configuration file in your `~/.pi/config/` directory:

```json
{
  "name": "my-web-search-config",
  "dependencies": {
    "web-search": "file:/path/to/web-search-extension.ts"
  },
  "env": {
    "WEB_SEARCH_PROVIDER": "duckduckgo"
  },
  "default": {
    "model": "claude-3.5-sonnet"
  }
}
```

### Option 2: Use with Existing Config

Add it as a dependency in your existing `pi-config.json`:

```json
{
  "dependencies": {
    "web-search": "file:./web-search-extension.ts"
  },
  "env": {
    "WEB_SEARCH_PROVIDER": "duckduckgo"
  }
}
```

## Configuration

Set environment variables in your configuration file:

### DuckDuckGo (No API Required)

```json
{
  "env": {
    "WEB_SEARCH_PROVIDER": "duckduckgo"
  }
}
```

### Bing Search (Requires API Key)

```json
{
  "env": {
    "WEB_SEARCH_PROVIDER": "bing",
    "WEB_SEARCH_API_KEY": "your-bing-api-key"
  }
}
```

Get a free Bing Search API key at: https://portal.azure.com/#view/Microsoft_Azure_ContainerRegistries/ContainerRegistryCreateMenuBlade/~/overview

### Custom API

```json
{
  "env": {
    "WEB_SEARCH_PROVIDER": "custom",
    "WEB_SEARCH_CUSTOM_URL": "https://api.example.com/search",
    "WEB_SEARCH_CUSTOM_API_KEY": "your-api-key-or-env:MY_API_KEY"
  }
}
```

## Usage

### Automatic Usage

The LLM will automatically use web search when appropriate, based on the prompt guidelines:

```
When do I use web search?
- Current information, facts, or research
- Information that might be outdated in training data
- Technical documentation or specifications
- Latest tools, libraries, or frameworks

Example: "Search for the latest version of React and its new features"
```

### Using the Tool Directly

The tool is available as `web_search`:

```
Search for information about TypeScript 5.0 features
```

### Using Commands

Or use the `/search` command:

```
/search latest React 2024 features
```

## Tool Parameters

- `query` (required): Search query - be specific and descriptive
- `maxResults` (optional, default: 5): Maximum results to return (1-20)
- `includeAnswers` (optional, default: true): Include direct answers if available

## Output Format

Results are returned in a structured format:

```
🔍 Web Search Results (3 found):

1. React 18 New Features
   https://react.dev/blog/2022/03/29/react-18
   React 18 introduces concurrent rendering, automatic batching...

2. TypeScript 5.0: Major Features
   https://www.typescriptlang.org/docs/handbook/release-notes/typescript-5.0.html
   Type predicates, decorators, and more...

💡 Tip: For research topics, consider cross-referencing multiple sources.
```

## Features

### DuckDuckGo Mode

Uses the DuckDuckGo Instant Answer API. No API key required. Provides instant answers for many queries.

### Bing Mode

Uses the Microsoft Bing Search API. Requires an API key. More comprehensive results with web pages.

### Custom Mode

Supports any custom search API. Configure your endpoint and API key in the environment variables.

### Cancellation

The tool respects abort signals, so users can cancel searches with `Ctrl+C`.

### Session Caching

Search results are cached per session for related queries, reducing API calls.

## Examples

### Find Latest Package Versions

```
Search for the latest version of lodash
```

### Research a Topic

```
Research the differences between Redux and Zustand state management
```

### Get Current Information

```
What's the latest version of Node.js as of March 2024?
```

## Troubleshooting

### Bing Search Failing

Make sure you've set `WEB_SEARCH_API_KEY` and that it's valid.

### No Results

- Try a simpler query
- Check if the provider is configured correctly
- For DuckDuckGo, some queries may not have instant answers

### Custom API Errors

Verify your custom API URL is correct and the endpoint supports the search format expected by the extension.

## License

MIT