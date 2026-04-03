/**
 * Interactive initialization wizard.
 * Replaces lib/init.sh
 */

import { existsSync, mkdirSync } from 'node:fs';
import { join } from 'node:path';
import { createRequire } from 'node:module';
import { saveConfig } from '../core/config.js';
import { logOk, logStep, printBanner } from '../core/logger.js';
import { setLang, t } from '../core/i18n.js';
import { detectAiCli, getModelsForBackend, refreshModelCache } from '../ai/backend.js';

export async function cmdInit({ rootDir, harnDir, scriptDir, configFile, version }) {
  const inquirer = (await import('inquirer')).default;

  printBanner(version);
  logStep(t('INIT_WELCOME'));

  // 1. Language
  const { lang } = await inquirer.prompt([{
    type: 'list', name: 'lang', message: t('INIT_LANG'),
    choices: [
      { name: 'English', value: 'en' },
      { name: '한국어', value: 'ko' },
    ],
    default: 'en',
  }]);
  setLang(lang);

  // 2. Max iterations
  const { maxIter } = await inquirer.prompt([{
    type: 'number', name: 'maxIter',
    message: t('INIT_ITERATIONS'),
    default: 5,
  }]);

  // 4. AI backend detection
  const backends = detectAiCli();
  if (backends.length === 0) {
    console.log('\n  ⚠  No AI CLI found. Install copilot, claude, codex, or gemini.\n');
  }

  let aiBackend = backends[0] || '';
  if (backends.length > 1) {
    const { chosen } = await inquirer.prompt([{
      type: 'list', name: 'chosen', message: t('INIT_AI'),
      choices: backends,
    }]);
    aiBackend = chosen;
  }

  // Refresh model cache
  mkdirSync(harnDir, { recursive: true });
  await refreshModelCache(harnDir);

  // 5. Per-role model selection
  const roleKeys = [
    { key: 'COPILOT_MODEL_PLANNER',            label: 'Planner',              default: 'claude-haiku-4.5' },
    { key: 'COPILOT_MODEL_GENERATOR_CONTRACT',  label: 'Generator (contract)', default: 'claude-sonnet-4.6' },
    { key: 'COPILOT_MODEL_GENERATOR_IMPL',      label: 'Generator (impl)',     default: 'claude-opus-4.6' },
    { key: 'COPILOT_MODEL_EVALUATOR_CONTRACT',   label: 'Evaluator (contract)', default: 'claude-haiku-4.5' },
    { key: 'COPILOT_MODEL_EVALUATOR_QA',         label: 'Evaluator (QA)',       default: 'claude-sonnet-4.5' },
  ];

  const modelChoices = getModelsForBackend(aiBackend, harnDir);
  const models = {};

  for (const role of roleKeys) {
    if (modelChoices.length > 0) {
      const { model } = await inquirer.prompt([{
        type: 'list', name: 'model',
        message: `${t('INIT_MODEL')} ${role.label}`,
        choices: modelChoices,
        default: role.default,
      }]);
      models[role.key] = model;
    } else {
      models[role.key] = role.default;
    }
  }

  // 6. Git integration
  const { gitEnabled } = await inquirer.prompt([{
    type: 'confirm', name: 'gitEnabled',
    message: t('INIT_GIT'),
    default: false,
  }]);

  // Write config
  const cfg = {
    HARN_LANG: lang,
    AI_BACKEND: aiBackend,
    MAX_ITERATIONS: String(maxIter),
    GIT_ENABLED: gitEnabled ? 'true' : 'false',
    ...models,
  };

  saveConfig(configFile, cfg);
  logOk(t('INIT_DONE'));
  return cfg;
}
