/**
 * Web Search Extension for pi
 *
 * Provides web search capabilities using a configurable search API.
 *
 * Features:
 * - Web search with configurable API (Bing, DuckDuckGo, or custom)
 * - Returns structured results with titles, URLs, snippets
 * - Cancellation support
 * - Progress updates
 *
 * Usage:
 *   - Add as dependency in your pi config
 *   - Call /search-tool <query> or let LLM use search when appropriate
 *
 * Configuration:
 *   Set environment variables:
 *   - WEB_SEARCH_API_KEY: API key for Bing Search (recommended)
 *   - WEB_SEARCH_PROVIDER: "bing" | "duckduckgo" | "custom"
 *   - WEB_SEARCH_CUSTOM_URL: Custom API endpoint URL
 *   - WEB_SEARCH_CUSTOM_API_KEY: Custom API key
 */

import { Type } from "@sinclair/typebox";
import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";

// Environment variables (configured by user)
const ENV = {
	API_KEY: process.env.WEB_SEARCH_API_KEY,
	PROVIDER: process.env.WEB_SEARCH_PROVIDER || "duckduckgo",
	CUSTOM_URL: process.env.WEB_SEARCH_CUSTOM_URL,
	CUSTOM_API_KEY: process.env.WEB_SEARCH_CUSTOM_API_KEY,
} as const;

const PROVIDERS = ["bing", "duckduckgo", "custom"] as const;
const ProviderSchema = Type.Literal(...PROVIDERS);

// Search result type
interface SearchResult {
	title: string;
	url: string;
	snippet: string;
	content?: string;
}

export default function webSearchExtension(pi: ExtensionAPI) {
	// Cache search results for the session
	const searchResults = new Map<string, SearchResult[]>();

	// Register web search tool
	pi.registerTool({
		name: "web_search",
		label: "Web Search",
		description: `Search the web for information using ${ENV.PROVIDER} provider`,
		promptSnippet: "Search the web for up-to-date information on any topic",
		promptGuidelines: [
			"Use web_search when you need current information, facts, or research that might be outdated in your training data.",
			"For research topics, provide a concise query that includes key terms.",
			"Review search results carefully and synthesize information from multiple sources when available.",
			"Always include source URLs for important claims.",
		],
		parameters: Type.Object({
			query: Type.String({
				description: "Search query - be specific and descriptive"
			}),
			maxResults: Type.Optional(Type.Number({
				description: "Maximum number of results to return (default: 5)",
				minimum: 1,
				maximum: 20,
				default: 5,
			})),
			includeAnswers: Type.Optional(Type.Boolean({
				description: "Include direct answers if available (default: true)",
				default: true,
			})),
		}),

		async execute(_toolCallId, params, signal, onUpdate, ctx) {
			const { query, maxResults = 5, includeAnswers = true } = params as {
				query: string;
				maxResults?: number;
				includeAnswers?: boolean;
			};

			if (signal?.aborted) {
				return {
					content: [{ type: "text", text: "Search cancelled" }],
					details: { cancelled: true },
				};
			}

			// Update progress
			onUpdate?.({
				content: [{ type: "text", text: `Searching web for: "${query}"...` }],
				details: { query, step: "searching" },
			});

			// Call search API
			const results = await performSearch(query, maxResults, includeAnswers, signal);

			// Store in cache
			searchResults.set(query, results);

			// Format output
			const output = formatResults(results, includeAnswers);

			return {
				content: [{ type: "text", text: output }],
				details: { query, resultsCount: results.length, provider: ENV.PROVIDER },
			};
		},

		renderCall: (args, theme, context) => {
			const { query } = args as { query: string };
			return {
				body: [
					{ type: "info", content: `Search: "${query}"` },
				],
			};
		},
	});

	// Register commands
	pi.registerCommand("search", {
		description: `Search the web: /search <query>`,
		handler: async (args, ctx) => {
			const query = (args as { _: string[] })?._?.join(" ") || "";
			if (!query) {
				ctx.ui.notify("Usage: /search <query>", "warning");
				return;
			}

			const results = await performSearch(query, 10, true, undefined, ctx);
			const output = formatResults(results, true);

			ctx.ui.notify("Web Search Results:", "info");
			ctx.ui.notify(output, "info");
		},
	});

	// Clear search cache on session end
	pi.on("session_end", (_event, ctx) => {
		searchResults.clear();
	});
}

/**
 * Perform web search based on configured provider
 */
async function performSearch(
	query: string,
	maxResults: number,
	includeAnswers: boolean,
	signal?: AbortSignal,
	ctx?: any
): Promise<SearchResult[]> {
	switch (ENV.PROVIDER) {
		case "bing":
			return await bingSearch(query, maxResults, signal, ctx);
		case "duckduckgo":
			return await duckDuckGoSearch(query, maxResults, signal, ctx);
		case "custom":
			return await customSearch(query, maxResults, signal, ctx);
		default:
			throw new Error(`Unsupported provider: ${ENV.PROVIDER}`);
	}
}

/**
 * Bing Search API implementation
 */
async function bingSearch(
	query: string,
	maxResults: number,
	signal?: AbortSignal,
	ctx?: any
): Promise<SearchResult[]> {
	if (!ENV.API_KEY) {
		throw new Error(
			"Bing Search requires WEB_SEARCH_API_KEY environment variable. " +
			"Set it in your pi configuration."
		);
	}

	try {
		const response = await fetch("https://api.bing.microsoft.com/v7.0/search", {
			method: "GET",
			headers: {
				"Ocp-Apim-Subscription-Key": ENV.API_KEY,
			},
			signal,
		});

		if (!response.ok) {
			const error = await response.text();
			throw new Error(`Bing Search failed (${response.status}): ${error}`);
		}

		const data = await response.json();
		const webPages = data.webPages?.value || [];

		return webPages
			.slice(0, maxResults)
			.map((page: any) => ({
				title: page.name,
				url: page.url,
				snippet: page.snippet,
			}));
	} catch (error) {
		if (signal?.aborted) {
			return [];
		}
		throw error;
	}
}

/**
 * DuckDuckGo HTML Search implementation (no API required)
 */
async function duckDuckGoSearch(
	query: string,
	maxResults: number,
	signal?: AbortSignal,
	ctx?: any
): Promise<SearchResult[]> {
	try {
		// Use DDG Instant Answer API
		const response = await fetch(
			`https://api.duckduckgo.com/?q=${encodeURIComponent(query)}&format=json&no_html=1`,
			{
				signal,
			}
		);

		if (!response.ok) {
			throw new Error(`DuckDuckGo search failed (${response.status})`);
		}

		const data = await response.json();

		// Process results
		const results: SearchResult[] = [];

		// Instant Answer
		if (data.AbstractText) {
			results.push({
				title: data.Heading || query,
				url: data.AbstractURL || "",
				snippet: data.AbstractText,
				content: data.AbstractText,
			});
		}

		// Related Topics
		if (data.RelatedTopics) {
			for (const topic of data.RelatedTopics.slice(0, maxResults - 1)) {
				if (topic.Text && topic.FirstURL) {
					results.push({
						title: topic.Text.replace(/<.*?>/g, ""),
						url: topic.FirstURL,
						snippet: topic.Text.replace(/<.*?>/g, ""),
					});
				}
			}
		}

		return results.slice(0, maxResults);
	} catch (error) {
		if (signal?.aborted) {
			return [];
		}
		throw error;
	}
}

/**
 * Custom API implementation
 */
async function customSearch(
	query: string,
	maxResults: number,
	signal?: AbortSignal,
	ctx?: any
): Promise<SearchResult[]> {
	if (!ENV.CUSTOM_URL) {
		throw new Error(
			"Custom search requires WEB_SEARCH_CUSTOM_URL environment variable. " +
			"Set it in your pi configuration."
		);
	}

	const apiKey = ENV.CUSTOM_API_KEY || "dummy";

	try {
		// Example: OpenAI compatible search endpoint
		const response = await fetch(`${ENV.CUSTOM_URL}/search`, {
			method: "POST",
			headers: {
				"Content-Type": "application/json",
				Authorization: apiKey.startsWith("env:") ? `Bearer ${process.env[apiKey.replace("env:", "")]}` : apiKey,
			},
			body: JSON.stringify({
				query,
				limit: maxResults,
			}),
			signal,
		});

		if (!response.ok) {
			const error = await response.text();
			throw new Error(`Custom search failed (${response.status}): ${error}`);
		}

		const data = await response.json();
		return data.results || [];
	} catch (error) {
		if (signal?.aborted) {
			return [];
		}
		throw error;
	}
}

/**
 * Format search results for display
 */
function formatResults(results: SearchResult[], includeAnswers: boolean): string {
	if (results.length === 0) {
		return "No results found. Try a different search query.";
	}

	let output = `🔍 Web Search Results (${results.length} found):\n\n`;

	results.forEach((result, index) => {
		output += `${index + 1}. ${result.title}\n`;
		output += `   ${result.url}\n`;

		if (result.content) {
			output += `   ${result.content}\n`;
		} else if (result.snippet) {
			output += `   ${result.snippet}\n`;
		}

		output += "\n";
	});

	if (includeAnswers) {
		output += "\n💡 Tip: For research topics, consider cross-referencing multiple sources.";
	}

	return output;
}