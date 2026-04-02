// src/ai/parser.js — Stream parsing and ANSI utilities
// Replaces parser/md_stream.py and parser/stream_parser.py

// ── ANSI stripping ───────────────────────────────────────────────────────────

const ANSI_RE = /\x1b\[[0-9;]*[A-Za-z]/g;

/**
 * Remove ANSI escape codes from text.
 * @param {string} text
 * @returns {string}
 */
export function stripAnsi(text) {
  if (!text) return '';
  return text.replace(ANSI_RE, '');
}

// ── Claude stream-json parsing ───────────────────────────────────────────────

/**
 * Parse a single line of Claude's `--output-format stream-json` output.
 *
 * Event types handled:
 * - stream_event / content_block_delta / text_delta → returns text token
 * - stream_event / content_block_start / tool_use → returns tool start marker
 * - stream_event / tool_result → returns tool result preview
 * - result → returns null (already printed via text tokens)
 * - error → returns error message
 *
 * @param {string} line - a single JSON line from the stream
 * @returns {{ type: string, text?: string, toolName?: string, error?: string } | null}
 *   - type: 'text' | 'tool_start' | 'tool_result' | 'error' | 'skip'
 *   - Returns null for unparseable or empty lines
 */
export function parseStreamJson(line) {
  if (!line || !line.trim()) return null;

  const trimmed = line.trim();

  let obj;
  try {
    obj = JSON.parse(trimmed);
  } catch {
    // Non-JSON line (error messages, etc.) — return as raw text
    return { type: 'text', text: trimmed + '\n' };
  }

  const t = obj.type || '';

  // ── Text tokens (real-time streaming) ──────────────────────────────────
  if (t === 'stream_event') {
    const event = obj.event || {};
    const et = event.type || '';

    if (et === 'content_block_delta') {
      const delta = event.delta || {};
      if (delta.type === 'text_delta' && delta.text) {
        return { type: 'text', text: delta.text };
      }
      return null;
    }

    if (et === 'content_block_start') {
      const block = event.content_block || {};
      if (block.type === 'tool_use') {
        return { type: 'tool_start', toolName: block.name || '?' };
      }
      return null;
    }

    if (et === 'tool_result') {
      const content = event.content || '';
      const preview = String(content).slice(0, 80).replace(/\n/g, ' ');
      return { type: 'tool_result', text: preview };
    }

    return null;
  }

  // ── Final result ───────────────────────────────────────────────────────
  if (t === 'result') {
    return { type: 'skip' };
  }

  // ── Error ──────────────────────────────────────────────────────────────
  if (t === 'error') {
    const msg = (obj.error && obj.error.message) || JSON.stringify(obj);
    return { type: 'error', error: msg };
  }

  return null;
}
