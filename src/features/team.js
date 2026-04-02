/**
 * Team mode — tmux-based parallel agent execution.
 * Replaces lib/team.sh
 */

import { execSync, spawn } from 'node:child_process';
import { logStep, logOk, logWarn } from '../core/logger.js';
import { t } from '../core/i18n.js';

const MAX_AGENTS = 8;

/** Check if tmux is available. */
export function hasTmux() {
  try {
    execSync('which tmux', { stdio: 'pipe' });
    return true;
  } catch {
    return false;
  }
}

/** Launch N parallel agents in tmux panes. */
export function cmdTeam(count, task, { config, rootDir, harnDir }) {
  const n = Math.min(Math.max(count || 3, 1), MAX_AGENTS);

  if (!hasTmux()) {
    logWarn('tmux is not installed. Install it with: brew install tmux');
    return false;
  }

  logStep(`Launching ${n} agents for: ${task}`);

  const session = `harn-team-${Date.now()}`;
  const backend = config.AI_BACKEND || 'copilot';
  const model = config.COPILOT_MODEL_GENERATOR_IMPL || 'claude-opus-4.6';

  // Create tmux session with first pane
  execSync(`tmux new-session -d -s ${session} -x 200 -y 50`, { stdio: 'pipe' });

  for (let i = 0; i < n; i++) {
    const agentNum = i + 1;
    const agentPrompt = [
      `You are Agent ${agentNum} of ${n} working on: ${task}`,
      `Focus on your portion of the work. Coordinate by checking git status.`,
      `Agent ${agentNum} should focus on the ${getAgentFocus(agentNum, n)} aspects.`,
    ].join('\n');

    const cmd = buildAgentCommand(backend, model, agentPrompt, rootDir);

    if (i === 0) {
      execSync(`tmux send-keys -t ${session} '${escapeTmux(cmd)}' Enter`, { stdio: 'pipe' });
    } else {
      execSync(`tmux split-window -t ${session} -h`, { stdio: 'pipe' });
      execSync(`tmux send-keys -t ${session} '${escapeTmux(cmd)}' Enter`, { stdio: 'pipe' });
      execSync(`tmux select-layout -t ${session} tiled`, { stdio: 'pipe' });
    }
  }

  // Attach to session
  logOk(`Team session: ${session} (${n} agents)`);
  console.log(`  Attach with: tmux attach -t ${session}`);

  try {
    execSync(`tmux attach -t ${session}`, { stdio: 'inherit' });
  } catch {
    // User detached
  }

  return true;
}

function buildAgentCommand(backend, model, prompt, rootDir) {
  const escaped = prompt.replace(/'/g, "'\\''");
  switch (backend) {
    case 'copilot':
      return `copilot --add-dir "${rootDir}" --yolo -p '${escaped}' --model ${model} --effort high`;
    case 'claude':
      return `claude -p '${escaped}' --model ${model}`;
    case 'codex':
      return `echo '${escaped}' | codex exec -m ${model} -`;
    default:
      return `copilot --add-dir "${rootDir}" --yolo -p '${escaped}' --model ${model}`;
  }
}

function getAgentFocus(num, total) {
  const focuses = ['core logic', 'UI/frontend', 'tests', 'documentation', 'API/backend', 'data/models', 'infrastructure', 'integration'];
  return focuses[(num - 1) % focuses.length];
}

function escapeTmux(str) {
  return str.replace(/'/g, "'\\''");
}
