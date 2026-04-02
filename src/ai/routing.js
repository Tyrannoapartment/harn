// src/ai/routing.js — Intelligent model routing based on prompt analysis
// Replaces lib/routing.sh

// ── Keyword lists ────────────────────────────────────────────────────────────

const ESCALATION_KEYWORDS = [
  'critical', 'security', 'architecture', 'production', 'migration',
  'breaking', 'vulnerability', 'performance', 'refactor', 'database',
];

const SIMPLIFICATION_KEYWORDS = [
  'find', 'list', 'search', 'format', 'rename',
  'typo', 'comment', 'docs', 'readme', 'changelog',
];

const ESCALATION_RE = new RegExp(ESCALATION_KEYWORDS.join('|'), 'i');
const SIMPLIFICATION_RE = new RegExp(
  `^\\s*(${SIMPLIFICATION_KEYWORDS.join('|')})`, 'i'
);

// ── Tier definitions ─────────────────────────────────────────────────────────

const TIERS = ['haiku', 'sonnet', 'opus'];

function upgrade(model) {
  if (model.includes('haiku'))  return { changed: true, model: model.replace('haiku', 'sonnet') };
  if (model.includes('sonnet')) return { changed: true, model: model.replace('sonnet', 'opus') };
  return { changed: false, model };
}

function downgrade(model) {
  if (model.includes('opus'))   return { changed: true, model: model.replace('opus', 'sonnet') };
  if (model.includes('sonnet')) return { changed: true, model: model.replace('sonnet', 'haiku') };
  return { changed: false, model };
}

// ── Exported ─────────────────────────────────────────────────────────────────

/**
 * Analyze prompt keywords and optionally upgrade/downgrade the model tier.
 *
 * - Escalation keywords (critical, security, etc.) → haiku→sonnet, sonnet→opus
 * - Simplification keywords at prompt start (find, list, etc.) → opus→sonnet, sonnet→haiku
 * - Only examines first 2000 characters of prompt
 * - Disabled when config.MODEL_ROUTING === 'false'
 *
 * @param {string} model - current model name (e.g. 'claude-sonnet-4.5')
 * @param {string} promptText - the full prompt text
 * @param {object} [config] - config object, may contain MODEL_ROUTING
 * @returns {string} - the (possibly adjusted) model name
 */
export function routeModel(model, promptText, config = {}) {
  // Disabled by config or env
  const routing = config.MODEL_ROUTING ?? process.env.MODEL_ROUTING ?? 'true';
  if (routing !== 'true' && routing !== true) return model;

  // Sample first 2000 chars, lowercase
  const sample = (promptText || '').slice(0, 2000).toLowerCase();

  // Check escalation
  if (ESCALATION_RE.test(sample)) {
    const result = upgrade(model);
    return result.model;
  }

  // Check simplification (must appear at start of prompt)
  if (SIMPLIFICATION_RE.test(sample)) {
    const result = downgrade(model);
    return result.model;
  }

  return model;
}
