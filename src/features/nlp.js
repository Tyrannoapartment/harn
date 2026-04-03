/**
 * NLP command router — `harn do "<request>"`.
 */

import { aiGenerate } from '../ai/backend.js';
import { logStep, logInfo } from '../core/logger.js';

const VALID_COMMANDS = ['auto', 'all', 'start', 'plan', 'resume', 'discover', 'add', 'backlog', 'status', 'web', 'doctor', 'init', 'team', 'memory'];

/** Extract team count from input like "3명" or "team 3". */
function extractTeamArgs(input) {
  const match = input.match(/(\d+)\s*(?:명|agents?|workers?|team)/i) || input.match(/team\s*(\d+)/i);
  return match ? parseInt(match[1], 10) : 3;
}

export async function routeNlp(input, config) {
  logStep('Parsing command…');
  const prompt = [
    'Parse this natural language request into a harn CLI command.',
    `Request: "${input}"`,
    `\nAvailable commands: ${VALID_COMMANDS.join(', ')}`,
    '\nRespond with ONLY the command name on a single line, nothing else.',
  ].join('\n');

  const result = await aiGenerate({
    prompt,
    backend: config.AI_BACKEND,
    model: config.MODEL_AUXILIARY || config.COPILOT_MODEL_PLANNER,
    cwd: process.cwd(),
  });

  const text = (result?.output || '').trim().toLowerCase();
  const cmd = text.split(/\s+/)[0];
  if (VALID_COMMANDS.includes(cmd)) {
    logInfo(`AI matched: harn ${cmd}`);
    return { command: cmd, args: cmd === 'team' ? [extractTeamArgs(input), input] : [input] };
  }

  logInfo(`Could not parse command. Defaulting to: harn auto`);
  return { command: 'auto', args: [input] };
}
