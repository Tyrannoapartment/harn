/**
 * NLP command router — `harn do "<request>"`.
 * Replaces lib/nlp.sh
 */

import { aiGenerate } from '../ai/backend.js';
import { logStep, logInfo } from '../core/logger.js';

const COMMAND_MAP = [
  { cmd: 'auto',     patterns: ['진행', '시작', 'start', 'auto', 'run', '다음'] },
  { cmd: 'discover', patterns: ['분석', '찾아', 'discover', 'find', 'scan', '탐색'] },
  { cmd: 'add',      patterns: ['추가', 'add', '등록', 'create task'] },
  { cmd: 'backlog',  patterns: ['백로그', 'backlog', '목록', 'list'] },
  { cmd: 'status',   patterns: ['상태', 'status', '진행상황'] },
  { cmd: 'plan',     patterns: ['계획', 'plan'] },
  { cmd: 'start',    patterns: ['시작', 'start', 'begin'] },
  { cmd: 'all',      patterns: ['전체', 'all', '모두'] },
  { cmd: 'resume',   patterns: ['재개', 'resume', '이어'] },
  { cmd: 'web',      patterns: ['웹', 'web', 'ui', '대시보드', 'dashboard'] },
  { cmd: 'doctor',   patterns: ['진단', 'doctor', 'check', '점검'] },
  { cmd: 'init',     patterns: ['초기화', 'init', 'setup', '설정'] },
  { cmd: 'team',     patterns: ['팀', 'team', '병렬', 'parallel'] },
  { cmd: 'memory',   patterns: ['메모리', 'memory', '학습', 'learn'] },
];

/** Quick keyword match (no AI needed). */
function quickMatch(input) {
  const lower = input.toLowerCase();
  for (const entry of COMMAND_MAP) {
    for (const p of entry.patterns) {
      if (lower.includes(p)) return entry.cmd;
    }
  }
  return null;
}

/** Extract team count from input like "3명" or "team 3". */
function extractTeamArgs(input) {
  const match = input.match(/(\d+)\s*(?:명|agents?|workers?|team)/i) || input.match(/team\s*(\d+)/i);
  return match ? parseInt(match[1], 10) : 3;
}

/** NLP-powered command routing. Falls back to AI if keyword match fails. */
export async function routeNlp(input, config) {
  // Try quick keyword match first
  const quick = quickMatch(input);
  if (quick) {
    logInfo(`Matched: harn ${quick}`);
    return { command: quick, args: quick === 'team' ? [extractTeamArgs(input), input] : [input] };
  }

  // AI fallback
  logStep('Parsing command…');
  const prompt = [
    'Parse this natural language request into a harn CLI command.',
    `Request: "${input}"`,
    '\nAvailable commands: auto, all, start, plan, resume, discover, add, backlog, status, web, doctor, init, team, memory',
    '\nRespond with ONLY the command name on a single line, nothing else.',
  ].join('\n');

  const output = await aiGenerate({
    prompt,
    backend: config.AI_BACKEND,
    model: config.MODEL_AUXILIARY || config.COPILOT_MODEL_PLANNER,
    cwd: process.cwd(),
  });

  const cmd = output.trim().toLowerCase().split(/\s+/)[0];
  const valid = COMMAND_MAP.map((e) => e.cmd);
  if (valid.includes(cmd)) {
    logInfo(`AI matched: harn ${cmd}`);
    return { command: cmd, args: [input] };
  }

  logInfo(`Could not parse command. Defaulting to: harn auto`);
  return { command: 'auto', args: [input] };
}
