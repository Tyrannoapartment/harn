/**
 * Internationalization — Korean / English UI strings.
 * Replaces the i18n portion of lib/config.sh
 */

let currentLang = 'en';

export const setLang = (lang) => { currentLang = lang === 'ko' ? 'ko' : 'en'; };
export const getLang = () => currentLang;

const strings = {
  // ── Config ────────────────────────────────────────────────────────────────
  NO_CONFIG_WARN:    { ko: '설정 파일이 없습니다.',                en: 'No configuration file found.' },
  NO_CONFIG_SETUP:   { ko: '`harn init`으로 설정을 시작합니다.',    en: 'Starting setup with `harn init`.' },

  // ── Backlog ───────────────────────────────────────────────────────────────
  BACKLOG_EMPTY:     { ko: '백로그가 비어 있습니다.',               en: 'Backlog is empty.' },
  BACKLOG_PENDING:   { ko: '대기 중인 항목',                       en: 'Pending items' },
  BACKLOG_SELECT:    { ko: '작업할 항목을 선택하세요:',             en: 'Select an item to work on:' },

  // ── Sprint ────────────────────────────────────────────────────────────────
  SPRINT_START:      { ko: '스프린트 시작',                        en: 'Sprint starting' },
  SPRINT_PASS:       { ko: '스프린트 통과',                        en: 'Sprint passed' },
  SPRINT_FAIL:       { ko: '스프린트 실패',                        en: 'Sprint failed' },
  SPRINT_SKIP:       { ko: '스프린트 건너뜀',                      en: 'Sprint skipped' },

  // ── Plan ──────────────────────────────────────────────────────────────────
  PLAN_START:        { ko: '플래너 호출 중…',                      en: 'Invoking planner…' },
  PLAN_DONE:         { ko: '계획 완료',                            en: 'Planning complete' },

  // ── Contract ──────────────────────────────────────────────────────────────
  CONTRACT_START:    { ko: '계약 협상 시작',                       en: 'Starting contract negotiation' },
  CONTRACT_APPROVED: { ko: '계약 승인됨',                          en: 'Contract approved' },
  CONTRACT_REVISION: { ko: '계약 수정 요청',                       en: 'Contract needs revision' },

  // ── Implement ─────────────────────────────────────────────────────────────
  IMPL_START:        { ko: '구현 시작',                            en: 'Starting implementation' },
  IMPL_DONE:         { ko: '구현 완료',                            en: 'Implementation complete' },

  // ── Evaluate ──────────────────────────────────────────────────────────────
  EVAL_START:        { ko: '평가 시작',                            en: 'Starting evaluation' },
  EVAL_PASS:         { ko: '평가 통과 — VERDICT: PASS',            en: 'Evaluation passed — VERDICT: PASS' },
  EVAL_FAIL:         { ko: '평가 실패 — VERDICT: FAIL',            en: 'Evaluation failed — VERDICT: FAIL' },

  // ── Next / Complete ───────────────────────────────────────────────────────
  NEXT_DONE:         { ko: '다음 스프린트로 이동',                  en: 'Moving to next sprint' },
  RUN_COMPLETE:      { ko: '실행 완료!',                           en: 'Run complete!' },

  // ── Auto ──────────────────────────────────────────────────────────────────
  AUTO_RESUME:       { ko: '진행 중인 작업을 재개합니다.',          en: 'Resuming in-progress work.' },
  AUTO_NO_PENDING:   { ko: '대기 중인 항목이 없습니다.',            en: 'No pending items.' },
  AUTO_DISCOVER:     { ko: '새 작업을 탐색합니다.',                 en: 'Discovering new tasks.' },

  // ── Stop / Clear / Exit ───────────────────────────────────────────────────
  STOP_CONFIRM:      { ko: '실행을 중지하시겠습니까?',              en: 'Stop the current run?' },
  CLEAR_CONFIRM:     { ko: '모든 실행 데이터를 삭제하시겠습니까?',   en: 'Clear all run data?' },
  EXIT_CONFIRM:      { ko: '서비스를 종료하시겠습니까?',             en: 'Shut down the service?' },

  // ── Doctor ────────────────────────────────────────────────────────────────
  DOCTOR_TITLE:      { ko: '시스템 진단',                           en: 'System diagnostics' },
  DOCTOR_OK:         { ko: '정상',                                  en: 'OK' },
  DOCTOR_WARN:       { ko: '경고',                                  en: 'Warning' },
  DOCTOR_ERR:        { ko: '오류',                                  en: 'Error' },

  // ── Init ──────────────────────────────────────────────────────────────────
  INIT_WELCOME:      { ko: 'harn 초기 설정을 시작합니다.',           en: 'Starting harn initial setup.' },
  INIT_LANG:         { ko: '언어를 선택하세요:',                     en: 'Select language:' },
  INIT_BACKLOG:      { ko: '백로그 파일 경로:',                      en: 'Backlog file path:' },
  INIT_ITERATIONS:   { ko: '최대 QA 반복 횟수:',                    en: 'Max QA iterations:' },
  INIT_AI:           { ko: 'AI 백엔드를 선택하세요:',                en: 'Select AI backend:' },
  INIT_MODEL:        { ko: '모델을 선택하세요:',                     en: 'Select model:' },
  INIT_GIT:          { ko: 'Git 통합을 활성화하시겠습니까?',          en: 'Enable Git integration?' },
  INIT_DONE:         { ko: '설정 완료!',                             en: 'Setup complete!' },

  // ── Web ───────────────────────────────────────────────────────────────────
  WEB_STARTING:      { ko: '웹 서버를 시작합니다…',                  en: 'Starting web server…' },
  WEB_RUNNING:       { ko: '웹 서버가 실행 중입니다.',                en: 'Web server is running.' },
  WEB_RECONNECT:     { ko: '기존 세션에 재접속합니다.',               en: 'Reconnecting to existing session.' },
  WEB_SHUTDOWN:      { ko: '웹 서버를 종료합니다.',                   en: 'Shutting down web server.' },

  // ── Errors ────────────────────────────────────────────────────────────────
  ERR_NO_RUN:        { ko: '활성 실행이 없습니다.',                   en: 'No active run.' },
  ERR_NO_BACKLOG:    { ko: '백로그 파일을 찾을 수 없습니다.',          en: 'Backlog file not found.' },
  ERR_AI_MISSING:    { ko: 'AI CLI가 설치되어 있지 않습니다.',         en: 'No AI CLI installed.' },
  ERR_COMMAND_RUNNING: { ko: '다른 명령이 실행 중입니다.',             en: 'Another command is already running.' },

  // ── Misc ──────────────────────────────────────────────────────────────────
  RETRO_START:       { ko: '회고 분석을 시작합니다.',                 en: 'Starting retrospective analysis.' },
  DISCOVER_START:    { ko: '코드베이스를 분석하여 작업을 탐색합니다.', en: 'Analyzing codebase to discover tasks.' },
  ADD_PROMPT:        { ko: '추가할 기능을 설명하세요:',                en: 'Describe the feature to add:' },
  GUIDANCE_HINT:     { ko: '추가 지시 사항 (Enter로 건너뛰기):',       en: 'Extra instructions (Enter to skip):' },
};

/**
 * Translate a key to the current language.
 * @param {string} key
 * @returns {string}
 */
export function t(key) {
  const entry = strings[key];
  if (!entry) return key;
  return entry[currentLang] || entry.en || key;
}
