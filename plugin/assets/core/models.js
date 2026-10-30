/* core/models.js — client-side model vocabulary shared by Agents + Providers.

   This is deliberately dependency-free: settings payloads do not yet carry an
   options[] catalog, so both surfaces need the same small provider-keyed
   fallback. Unknown values remain first-class — modelOptions() always keeps the
   current value at the front instead of silently replacing it. */

export const MODEL_VOCABULARY = Object.freeze({
  claude: Object.freeze([
    "claude-sonnet-5-5", "claude-opus-4-8", "claude-fable-5", "claude-sonnet-5", "claude-haiku-4-5",
    "opus", "fable", "sonnet", "haiku",
  ]),
  codex: Object.freeze([
    "gpt-5.6-sol", "gpt-5.6", "gpt-5.6-terra", "gpt-5.6-luna", "gpt-5.5", "gpt-5.3-codex",
  ]),
  gemini: Object.freeze([
    "gemini-3.1-pro-preview", "gemini-3-pro", "gemini-3-flash", "gemini-3.5-flash", "gemini-2.5-pro",
  ]),
  cursor: Object.freeze([
    "auto", "gpt-5.3-codex", "gpt-5.3-codex-low", "gpt-5.3-codex-high",
    "gpt-5.3-codex-xhigh", "gpt-5.2", "cursor-grok-4.5-high",
  ]),
  opencode: Object.freeze([
    "anthropic/claude-sonnet-4-5", "anthropic/claude-opus-4-8",
    "openai/gpt-5.6", "google/gemini-3-pro",
  ]),
  grok: Object.freeze([]),
});

export function modelOptions(provider, current) {
  const family = MODEL_VOCABULARY[String(provider || "").toLowerCase()] || [];
  const selected = current == null ? "" : String(current);
  return [...new Set([selected, ...family])];
}
