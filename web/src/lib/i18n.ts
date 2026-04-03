/**
 * Frontend i18n — translation dictionary for all UI strings.
 * Keys are grouped by component/area.
 */

type Lang = 'en' | 'ko'
type Translations = Record<string, { en: string; ko: string }>

const strings: Translations = {
  // ── Navigation ──
  'nav.console': { en: 'Console', ko: '콘솔' },
  'nav.backlog': { en: 'Backlog', ko: '백로그' },
  'nav.runs': { en: 'Runs', ko: '실행' },
  'nav.prompts': { en: 'Prompts', ko: '프롬프트' },
  'nav.memory': { en: 'Memory', ko: '메모리' },
  'nav.settings': { en: 'Settings', ko: '설정' },

  // ── Header ──
  'header.running': { en: 'Running', ko: '실행중' },
  'header.error': { en: 'Error', ko: '오류' },
  'header.waiting': { en: 'Waiting', ko: '대기중' },
  'header.auto': { en: 'Auto', ko: '자동' },
  'header.stop': { en: 'Stop', ko: '중지' },
  'header.autoTooltip': { en: 'Run next backlog item automatically', ko: '다음 백로그 항목 자동 실행' },
  'header.stopTooltip': { en: 'Stop current run', ko: '현재 실행 중지' },
  'header.toggleTheme': { en: 'Toggle theme', ko: '테마 전환' },

  // ── Page titles ──
  'page.console': { en: 'Console', ko: '콘솔' },
  'page.backlog': { en: 'Backlog', ko: '백로그' },
  'page.runs': { en: 'Runs', ko: '실행' },
  'page.prompts': { en: 'Prompts', ko: '프롬프트' },
  'page.settings': { en: 'Settings', ko: '설정' },
  'page.memory': { en: 'Project Memory', ko: '프로젝트 메모리' },

  // ── Console ──
  'console.newConsole': { en: 'New console', ko: '새 콘솔' },
  'console.clearConsole': { en: 'Clear console', ko: '콘솔 지우기' },
  'console.noResponse': { en: 'No response received. Check that an AI CLI (copilot, claude, codex, or gemini) is installed and configured in Settings.', ko: 'AI 응답을 받지 못했습니다. AI CLI(copilot, claude, codex, gemini)가 설치되어 있고 설정에서 구성되어 있는지 확인하세요.' },
  'console.thinking': { en: 'Thinking…', ko: '생각중…' },
  'console.placeholder': { en: 'Ask Harn anything… (backlog, sprints, settings)', ko: 'Harn에게 무엇이든 물어보세요… (백로그, 스프린트, 설정)' },

  // ── Backlog ──
  'backlog.empty': { en: 'Backlog is empty', ko: '백로그가 비어 있습니다' },
  'backlog.addFirst': { en: 'Add first item', ko: '첫 번째 항목 추가' },
  'backlog.addTitle': { en: 'Add Backlog Item', ko: '백로그 항목 추가' },
  'backlog.search': { en: 'Search by slug or description…', ko: '슬러그 또는 설명으로 검색…' },
  'backlog.pending': { en: 'Pending', ko: '대기중' },
  'backlog.inProgress': { en: 'In Progress', ko: '진행중' },
  'backlog.done': { en: 'Done', ko: '완료' },
  'backlog.emptySection': { en: 'Empty', ko: '비어 있음' },
  'backlog.slug': { en: 'Slug', ko: '슬러그' },
  'backlog.slugHint': { en: 'Spaces are automatically converted to hyphens', ko: '공백은 하이픈으로 자동 변환됩니다' },
  'backlog.description': { en: 'Description', ko: '설명' },
  'backlog.plan': { en: 'Plan', ko: '계획' },
  'backlog.planHint': { en: '(one-line summary)', ko: '(한 줄 요약)' },
  'backlog.status': { en: 'Status', ko: '상태' },
  'backlog.start': { en: 'Start', ko: '시작' },
  'backlog.close': { en: 'Close', ko: '닫기' },
  'backlog.cancel': { en: 'Cancel', ko: '취소' },
  'backlog.add': { en: 'Add', ko: '추가' },
  'backlog.adding': { en: 'Adding…', ko: '추가중…' },
  'backlog.details': { en: 'Details', ko: '상세' },
  'backlog.delete': { en: 'Delete', ko: '삭제' },
  'backlog.edit': { en: 'Edit', ko: '수정' },
  'backlog.editTitle': { en: 'Edit Backlog Item', ko: '백로그 항목 수정' },
  'backlog.save': { en: 'Save', ko: '저장' },
  'backlog.saving': { en: 'Saving…', ko: '저장중…' },
  'backlog.deleteConfirm': { en: 'Are you sure you want to delete this item?', ko: '이 항목을 삭제하시겠습니까?' },
  'backlog.deleting': { en: 'Deleting…', ko: '삭제중…' },
  'backlog.summary': { en: 'Summary', ko: '요약' },
  'backlog.summaryHint': { en: 'One-line summary of this ticket', ko: '이 티켓의 한 줄 요약' },
  'backlog.affectedFiles': { en: 'Affected Files', ko: '영향 파일' },
  'backlog.affectedFilesHint': { en: 'File paths (one per line)', ko: '파일 경로 (한 줄에 하나씩)' },
  'backlog.implementationGuide': { en: 'Implementation Guide', ko: '구현 가이드' },
  'backlog.implementationGuideHint': { en: 'Step-by-step implementation approach', ko: '단계별 구현 방법' },
  'backlog.acceptanceCriteria': { en: 'Acceptance Criteria', ko: '완료 조건' },
  'backlog.acceptanceCriteriaHint': { en: 'Criteria for completion (one per line)', ko: '완료 기준 (한 줄에 하나씩)' },
  'backlog.viewRaw': { en: 'Raw Markdown', ko: '마크다운 원문' },
  'backlog.viewFormatted': { en: 'Formatted', ko: '포맷 뷰' },

  // ── Runs ──
  'runs.empty': { en: 'No runs yet', ko: '실행 기록이 없습니다' },
  'runs.running': { en: 'Running', ko: '실행중' },
  'runs.done': { en: 'Done', ko: '완료' },
  'runs.active': { en: 'Active', ko: '활성' },
  'runs.pass': { en: 'Pass', ko: '통과' },
  'runs.fail': { en: 'Fail', ko: '실패' },
  'runs.cancelled': { en: 'Cancelled', ko: '취소됨' },
  'runs.sprint': { en: 'Sprint', ko: '스프린트' },

  // ── Phase labels ──
  'phase.starting': { en: 'Starting…', ko: '시작중…' },
  'phase.contract': { en: 'Negotiating contract', ko: '계약 협상중' },
  'phase.implement': { en: 'Implementing', ko: '구현중' },
  'phase.evaluate': { en: 'Evaluating', ko: '평가중' },
  'phase.next': { en: 'Advancing', ko: '진행중' },
  'phase.pass': { en: 'Passed ✓', ko: '통과 ✓' },
  'phase.fail': { en: 'Failed ✗', ko: '실패 ✗' },
  'phase.complete': { en: 'Complete', ko: '완료' },

  // ── Settings ──
  'settings.save': { en: 'Save', ko: '저장' },
  'settings.saved': { en: 'Saved ✓', ko: '저장됨 ✓' },
  'settings.aiBackend': { en: 'AI Backend', ko: 'AI 백엔드' },
  'settings.models': { en: 'Models', ko: '모델' },
  'settings.refresh': { en: 'Refresh', ko: '새로고침' },
  'settings.refreshing': { en: 'Refreshing…', ko: '새로고침중…' },
  'settings.selectModel': { en: 'Select model', ko: '모델 선택' },
  'settings.selectBackend': { en: 'Select AI CLI', ko: 'AI CLI 선택' },
  'settings.sprint': { en: 'Sprint', ko: '스프린트' },
  'settings.maxIterations': { en: 'Max Iterations', ko: '최대 반복 횟수' },
  'settings.routing': { en: 'Routing', ko: '라우팅' },
  'settings.smartRouting': { en: 'Smart Model Routing', ko: '스마트 모델 라우팅' },
  'settings.smartRoutingDesc': { en: 'Auto-upgrade/downgrade based on task complexity', ko: '작업 복잡도에 따라 모델 자동 조정' },
  'settings.language': { en: 'Language', ko: '언어' },
  'settings.uiLanguage': { en: 'UI & Prompt Language', ko: 'UI 및 프롬프트 언어' },
  'settings.selectLanguage': { en: 'Select language', ko: '언어 선택' },
  'settings.languageDesc': { en: 'Controls UI messages and agent prompt language', ko: 'UI 메시지 및 에이전트 프롬프트 언어 설정' },
  'settings.backendStatus': { en: 'Status', ko: '상태' },
  'settings.installed': { en: 'Installed', ko: '설치됨' },
  'settings.notInstalled': { en: 'Not installed', ko: '미설치' },
  'settings.checking': { en: 'Checking…', ko: '확인중…' },
  'settings.planner': { en: 'Planner', ko: '플래너' },
  'settings.generatorContract': { en: 'Generator (Contract)', ko: '제너레이터 (계약)' },
  'settings.generatorImpl': { en: 'Generator (Impl)', ko: '제너레이터 (구현)' },
  'settings.evaluatorContract': { en: 'Evaluator (Contract)', ko: '평가자 (계약)' },
  'settings.evaluatorQA': { en: 'Evaluator (QA)', ko: '평가자 (QA)' },
  'settings.auxiliary': { en: 'Auxiliary (Chat)', ko: '보조 (채팅)' },

  // ── Prompts ──
  'prompts.files': { en: 'Prompt Files', ko: '프롬프트 파일' },
  'prompts.selectToView': { en: 'Select a prompt to view', ko: '프롬프트를 선택하세요' },
  'prompts.edit': { en: 'Edit', ko: '수정' },
  'prompts.cancel': { en: 'Cancel', ko: '취소' },
  'prompts.saving': { en: 'Saving…', ko: '저장중…' },
  'prompts.saveAsCustom': { en: 'Save as Custom', ko: '커스텀으로 저장' },
  'prompts.empty': { en: '(empty)', ko: '(비어 있음)' },

  // ── MCP ──
  'settings.mcp': { en: 'MCP Servers', ko: 'MCP 서버' },
  'settings.mcpDesc': { en: 'Model Context Protocol servers provide tools and context to AI agents', ko: 'MCP 서버는 AI 에이전트에게 도구와 컨텍스트를 제공합니다' },
  'settings.mcpEmpty': { en: 'No MCP servers configured', ko: '설정된 MCP 서버가 없습니다' },
  'settings.mcpAdd': { en: 'Add Server', ko: '서버 추가' },
  'settings.mcpName': { en: 'Server Name', ko: '서버 이름' },
  'settings.mcpType': { en: 'Type', ko: '타입' },
  'settings.mcpUrl': { en: 'URL', ko: 'URL' },
  'settings.mcpCommand': { en: 'Command', ko: '명령어' },
  'settings.mcpArgs': { en: 'Arguments', ko: '인수' },
  'settings.mcpEnv': { en: 'Environment Variables', ko: '환경 변수' },
  'settings.mcpScope': { en: 'Scope', ko: '범위' },
  'settings.mcpGlobal': { en: 'Global', ko: '전역' },
  'settings.mcpProject': { en: 'Project', ko: '프로젝트' },
  'settings.mcpCli': { en: 'CLI', ko: 'CLI' },
  'settings.mcpRemove': { en: 'Remove', ko: '삭제' },
  'settings.mcpSave': { en: 'Save', ko: '저장' },

  // ── Memory ──
  'memory.empty': { en: 'No memory yet', ko: '메모리가 없습니다' },
  'memory.hint': { en: 'Memory is saved from retrospectives', ko: '회고에서 메모리가 저장됩니다' },

  // ── Common ──
  'common.error': { en: 'Error', ko: '오류' },
}

let currentLang: Lang = 'en'
const listeners: Set<() => void> = new Set()

export function setLang(lang: string) {
  const newLang: Lang = lang === 'ko' ? 'ko' : 'en'
  if (newLang !== currentLang) {
    currentLang = newLang
    listeners.forEach((fn) => fn())
  }
}

export function getLang(): Lang {
  return currentLang
}

export function t(key: string): string {
  const entry = strings[key]
  if (!entry) return key
  return entry[currentLang] || entry.en || key
}

export function onLangChange(fn: () => void): () => void {
  listeners.add(fn)
  return () => listeners.delete(fn)
}
