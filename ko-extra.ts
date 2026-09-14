/**
 * ko-extra.ts — ko.ts 에 빠져 있는 키의 한국어 번역.
 *
 * 원본 저장소의 ko.ts 는 영어 대비 약 48% 가 비어 있다. 그중 학부
 * 구조해석 강의에서 실제로 화면에 뜨는 것만 골라 채운 파일이다.
 * PRO 전용 화면, 철근 상세, CAD 가져오기, 랜딩 페이지는 제외했다.
 *
 * ko.ts 를 직접 고치지 않고 별도 파일로 두는 이유는 저장소를 매번 새로
 * 클론하기 때문이다. 병합은 store.svelte.ts 에서 { ...ko, ...koExtra }
 * 로 이루어지므로, 원본이 갱신되어도 이 파일만 다시 얹으면 된다.
 *
 * 용어 기준
 *   member      부재        node        절점
 *   support     지점        release     해제
 *   local axes  국부축      diagram     선도
 *   utilisation 이용률      shell       판요소
 */

// Record<string, string> 로 둔다. Partial<Translations> 는 값 타입을
// string | undefined 로 만들어, 스프레드 결과가 Translations 에
// 대입되지 않는다.
const koExtra: Record<string, string> = {
  // ── 고급 해석 ────────────────────────────────────────────────
  'advanced.despiece': '자유물체도',
  'advanced.jointsUnsupported': '내부 3D 절점은 선형 정적해석에서만 반영됩니다.',
  'advanced.only2d': '현재 2D 전용',
  'advanced.sliding3dUnsupported': '미끄럼 절점은 현재 2D 선형 정적해석에서만 지원됩니다.',
  'advanced.slidingUnsupported': '미끄럼 절점은 선형 정적해석에서만 지원됩니다.',

  // ── 앱 공통 ──────────────────────────────────────────────────
  'app.backHome': '처음으로',
  'app.language': '언어',

  // ── 계산서 ───────────────────────────────────────────────────
  'calcReport.cancel': '취소',
  'calcReport.companyName': '회사',
  'calcReport.engineerName': '기술자',
  'calcReport.generate': '계산서 생성',
  'calcReport.noResults': '해석을 먼저 실행하세요. 보고할 결과가 없습니다.',
  'calcReport.notes': '비고 / 가정',
  'calcReport.optional': '선택',
  'calcReport.projectName': '프로젝트명',
  'calcReport.title': '계산서 생성',

  // ── 단면 카탈로그 ────────────────────────────────────────────
  'cat.allCodes': '전체',
  'cat.code': '규격',
  'cat.geomApprox': '근사 외형',
  'cat.geomExact': '정확한 외형',
  'cat.geometry': '형상',
  'cat.missing': '아직 제공되지 않음',
  'cat.standard': '표준',

  // ── 하중 조합 ────────────────────────────────────────────────
  'combos.needsRecalcSolve': '조합이 현재 모델과 맞지 않습니다. 다시 계산하세요.',

  // ── 환경 설정 ────────────────────────────────────────────────
  'config.autoSplitElements': '부재 위에 절점을 놓으면 자동으로 분할',
  'config.close': '닫기',
  'config.drawPositiveTowardLocalAxes': '양의 결과를 국부축 방향으로 표시',
  'config.gridExtent': '격자 범위',
  'config.localAxesAlways': '전체',
  'config.localAxesMembers': '국부축 (부재)',
  'config.localAxesNever': '없음',
  'config.localAxesSelected': '선택 항목',
  'config.localAxesShells': '국부축 (판요소)',
  'config.smoothOrbit': '부드러운 회전 (저해상도)',

  'config.tip.autoSplit':
    '기존 부재 위에 절점을 놓으면 그 위치에서 두 개로 나뉩니다. 꺼두면 부재는 그대로 두고 절점만 겹쳐 놓입니다.',
  'config.tip.axisConvention':
    '국부축이 따르는 오른손/왼손 법칙입니다. 부재 내력의 부호를 결정합니다.',
  'config.tip.color':
    '부재를 모두 같은 색으로 칠할지, 재료나 단면에 따라 구분할지 정합니다.',
  'config.tip.drawPositiveTowardLocalAxes':
    '양의 값을 어느 쪽에 그릴지 정합니다. 부재의 국부축 방향으로 그리거나, 반대쪽으로 그립니다.',
  'config.tip.elementIds':
    '각 부재에 번호를 표시합니다. 결과표의 값이 어느 부재의 것인지 찾기 쉬워집니다.',
  'config.tip.gridExtent':
    '격자가 원점에서 얼마나 멀리까지 뻗는지 정합니다. 보이는 범위일 뿐 모델 크기를 제한하지는 않습니다.',
  'config.tip.gridSize':
    '격자선 사이 간격입니다. 절점이 이동하는 최소 단위이기도 합니다.',
  'config.tip.hideLoadsWithDiagram':
    '선도가 화면에 있는 동안 하중 화살표를 숨깁니다. 그림이 겹치지 않아 읽기 편합니다.',
  'config.tip.lengths':
    '모든 부재에 길이를 표시합니다. 잘못 입력한 좌표를 빠르게 찾을 수 있습니다.',
  'config.tip.localAxes':
    '각 부재의 고유 축을 표시합니다. 내력의 방향이 이 축을 기준으로 정해집니다.',
  'config.tip.localAxesShells':
    '판요소에 대해 같은 것을 표시합니다. 휨모멘트의 방향 기준이 됩니다.',
  'config.tip.momentStyle':
    '모멘트를 그리는 방식입니다. 축을 따라가는 이중 화살표 또는 회전 화살표 중에서 고릅니다.',
  'config.tip.nodeIds':
    '각 절점 옆에 번호를 표시합니다. 결과표에 쓰이는 번호와 같습니다.',
  'config.tip.renderMode':
    '부재를 선으로, 굵은 막대로, 또는 실제 단면 형상으로 표시합니다.',
  'config.tip.showAxes': '원점에 전역 X, Y, Z 축을 그려 방향을 확인할 수 있게 합니다.',
  'config.tip.showConstraintForces':
    '강제변위와 강체 구속이 전달하는 힘을 표시합니다.',
  'config.tip.showGrid':
    '모델 뒤의 기준 격자입니다. 꺼도 격자 스냅 기능은 그대로 동작합니다.',
  'config.tip.showLoads':
    '모델에 작용하는 하중을 표시합니다. 꺼도 하중 자체는 그대로 남아 해석에 반영됩니다.',
  'config.tip.showPrimarySelector':
    '어떤 결과를 화면에 표시할지 고르는 선택기입니다.',
  'config.tip.showReactions':
    '지점이 구조물에 되돌려주는 힘을 표시합니다.',
  'config.tip.showSecondarySelector':
    '"비교" 선택기입니다. 두 번째 결과를 겹쳐서 보여줍니다.',
  'config.tip.showValues':
    '선도 위에 숫자를 표시합니다. 최대값과 양 끝 값이 나옵니다.',
  'config.tip.smoothOrbit':
    '마우스를 놓은 뒤에도 카메라가 잠시 관성으로 움직입니다.',
  'config.tip.snapGrid':
    '새 절점이 정확히 클릭한 자리가 아니라 가장 가까운 격자 교점에 놓입니다.',
  'config.tip.units': '모든 입력란과 결과에 쓰이는 단위계입니다.',

  // ── 상세 / 검토 ──────────────────────────────────────────────
  'detailing.footingRun.activeResultSet': '활성 결과 세트 (풀린 조합 없음)',
  'detailing.review.notRecorded': '검토 내용을 기록하지 못했습니다.',

  // ── 진단 ─────────────────────────────────────────────────────
  'diag.model.transverseOnTruss':
    '이 부재는 축력만 받는 트러스로 모델링되어 있습니다. 여기에 작용하는 횡방향 하중은 휨이나 전단으로 전달되지 않습니다. 하중을 인접 절점에 옮기거나, 부재를 골조 부재로 바꾸는 것을 검토하세요.',

  'dialog.catalogueIsRolledSteel':
    '이 카탈로그는 열간압연 및 냉간성형 강재입니다. 제철소에서 생산하는 형상들입니다. 콘크리트, 목재, 알루미늄을 쓰시려면 «단면 만들기»에서 치수를 직접 입력하세요. 형상은 재료와 무관합니다.',

  // ── 편집기 ───────────────────────────────────────────────────
  'editor.joint3dHint':
    '각 단부에서 해제되는 상대 자유도입니다. 지반에 대한 지점이 아니라 부재 사이의 내부 절점입니다. dx/dy/dz는 병진, θx/θy/θz는 회전입니다.',
  'editor.joint3dTitle': '내부 절점 — 상대 자유도 해제',
  'editor.slideEnd': '끝단 미끄럼',
  'editor.slideNone': '없음',
  'editor.slideStart': '시작단 미끄럼',
  'editor.slideX': 'X 미끄럼',
  'editor.slideZ': 'Z 미끄럼',

  // ── 자동 저장 ────────────────────────────────────────────────
  'file.autosaveCorrupt':
    '자동 저장본이 있으나 읽을 수 없어 복원하지 못했습니다. .ded 파일을 직접 여세요.',
  'file.autosaveDegraded':
    'IndexedDB를 쓸 수 없어 자동 저장이 브라우저 저장소로 대체되었습니다. 용량이 수 MB로 제한되므로 큰 프로젝트는 담기지 않을 수 있습니다. 탭 저장으로 .ded 파일을 만들어 두세요.',
  'file.autosaveFailed':
    '자동 저장에 실패했습니다. 최근 작업이 저장되지 않았습니다. 탭 저장으로 .ded 파일을 만드세요.',
  'file.autosaveOlderRestored':
    '가장 최근 자동 저장본을 읽을 수 없어 그 이전 것을 제시합니다. 계속하기 전에 프로젝트 날짜를 확인하세요.',
  'file.autosaveTooLarge':
    '이 프로젝트가 너무 커져 브라우저에 자동 저장할 수 없습니다. 설계 실행 이후의 작업은 저장본에 없습니다. 탭 저장으로 .ded 파일을 만드세요.',
  'file.autosaveUnavailable':
    '이 브라우저에는 앱이 쓸 수 있는 저장소가 없어 자동 저장이 전혀 되지 않습니다. 탭 저장을 자주 해 .ded 파일로 보관하세요.',
  'file.autosaveUnfinished':
    '마지막 자동 저장이 끝나지 못했습니다. 저장 도중에 탭이 닫힌 것으로 보입니다. 아래는 그 이전 저장본입니다.',
  'file.loadedNoAxisConvention':
    '국부축 규약 정보 없이 불러왔습니다. 수정된 Z-상향 국부축 규약으로 평가됩니다. 다시 해석한 뒤 부재 선도와 검토 결과를 확인하세요.',

  // ── 떠 있는 도구모음 ─────────────────────────────────────────
  'float.joint3dDofHint': '이 절점이 해제할 상대 자유도를 켜고 끕니다 (지점이 아닌 내부 해제).',
  'float.joint3dHint': '해제할 상대 자유도를 고른 뒤, 부재의 단부 근처를 클릭하세요.',
  'float.joint3dRelease': '해제 (상대):',
  'float.jointAxis': '축:',
  'float.jointAxisGlobal': '전역',
  'float.jointAxisGlobalHint': '전역 X/Z 방향으로 미끄러집니다.',
  'float.jointAxisLocal': '국부',
  'float.jointAxisLocalHint': '부재 국부축 방향으로 미끄러집니다. 경사 부재에 적합합니다.',
  'float.jointHinge': '힌지',
  'float.jointHingeHint': '회전 해제입니다. 모멘트는 풀리고 병진은 묶여 있습니다.',
  'float.jointPickDof': '해제할 자유도를 최소 하나(dx…θz) 고르세요.',
  'float.jointSlideHint': '부재의 단부 근처를 클릭해 미끄럼 절점을 넣거나 뺍니다.',
  'float.jointSlideX': 'X 미끄럼',
  'float.jointSlideXHint': '미끄럼 절점: X 병진을 해제하고 Z와 회전은 묶어 둡니다.',
  'float.jointSlideZ': 'Z 미끄럼',
  'float.jointSlideZHint': '미끄럼 절점: Z 병진을 해제하고 X와 회전은 묶어 둡니다.',
  'float.nodeJoints': '절점 해제',

  // ── 운동학 판정 ──────────────────────────────────────────────
  'kin.slideExplain':
    '부재 {elem} ({end}): 미끄럼 절점 ({dir}, {axis} 축) → 상대 병진 1개 해제 → c += 1',
  'kinematic.rankUnavailable':
    '⏳ 아직 확인되지 않았습니다. 계산 엔진이 로딩 중이라 안정성이 확정되지 않았습니다.',
  'kinematic.slideAxisNote':
    '미끄럼 절점 하나마다 c가 1씩 늘어납니다. 축(전역 X/Z 또는 부재 국부 x/z)은 어느 상대 병진이 해제되는지만 정할 뿐, 개수를 바꾸지는 않습니다.',

  // ── 재료 규격 ────────────────────────────────────────────────
  'matCode.aboutCode': '이 규격에 대하여',
  'matCode.body': '제정',
  'matCode.since': '시행',

  // ── 부재 편심 ────────────────────────────────────────────────
  'pro.memberOffset': '부재 오프셋 (편심)',
  'pro.offsetActive': '이 부재에 오프셋이 적용되어 있습니다.',
  'pro.offsetApply': '오프셋 적용',
  'pro.offsetClear': '지우기',
  'pro.offsetEmbedWarn':
    '이 평면 모델은 2D 임베딩으로 풀리므로 부재 오프셋이 해석에 반영되지 않습니다.',
  'pro.offsetFrame': '기준',
  'pro.offsetGlobal': '전역 (X/Y/Z)',
  'pro.offsetLocal': '국부 (y/z)',
  'pro.offsetWarn': '해석 결과가 달라집니다. 접합부에 편심 모멘트가 생깁니다.',
  'proRibbon.reopenPanel': '패널 열기',

  // ── 프로젝트 패널 ────────────────────────────────────────────
  'project.fileSection': '파일',
  'project.openDxfCadTooltip': '건축 DXF 도면을 가져와 철근콘크리트 초안을 생성 (마법사)',

  // ── 결과 표시 ────────────────────────────────────────────────
  'results.asColourMap': '색상 지도',
  'results.asDiagram': '선도',
  'results.asMemberColour': '부재 색상',
  'results.measureSigmaMax': '수직응력 (σ)',
  'results.measureSigmaMaxHelp': '최대 수직응력입니다. 축응력과 휨응력의 합이며 단위는 MPa입니다.',
  'results.measureTauMax': '전단응력 (τ)',
  'results.measureTauMaxHelp':
    '최대 전단응력입니다(MPa). 수직응력과 비교해 어느 쪽이 지배하는지 볼 수 있습니다.',
  'results.measureUtilisation': '이용률 σ/fy',
  'results.measureUtilisationHelp':
    '폰 미세스 응력을 항복강도로 나눈 값입니다. 1.00이면 부재가 한계에 도달했다는 뜻이며, 그 자체로 의미를 갖는 유일한 지표입니다.',
  'results.measureVonMises': '폰 미세스 (σvm)',
  'results.measureVonMisesHelp':
    '조합응력입니다(MPa). 수직응력과 전단응력을 하나의 값으로 묶습니다.',
  'results.noYield':
    '항복강도가 지정되지 않은 부재는 이용률을 표시할 수 없어 칠하지 않습니다. 재료에 fy를 입력하거나 다른 지표를 고르세요.',
  'results.repColourMapHelp':
    '부호를 무시하고 크기에 따라 부재를 칠합니다. 파랑(작음)에서 빨강(큼)까지이며, 최대값의 위치를 보여줍니다.',
  'results.repDiagramHelp': '각 부재를 따라 값을 축척에 맞게 그립니다.',
  'results.repMemberColourHelp':
    '부호에 따라 부재를 칠합니다. 인장은 빨강, 압축은 파랑입니다. 크기가 아니라 방향을 보여줍니다.',
  'results.shellContourNegligible':
    '이 모델에서는 0에 가깝습니다. 지배적인 성분에 비해 무시할 수 있습니다(예: 휨을 받는 슬래브의 막응력, 면내 하중을 받는 벽의 휨).',
  'results.shellContourUnavailable':
    '등고선으로 그릴 판요소 결과가 없습니다. 판이나 사각요소가 있는 모델을 먼저 해석하세요.',
  'results.shellContourUniform': '균일한 분포입니다(위치에 따른 변화 없음). 약 {v}.',
  'results.showScale': '색상 범례 표시',
  'results.shownAs': '표시 방식',
  'results.stressMeasure': '지표',
  'results.verification': '검증',
  'resultsTable.diagnostics': '진단',

  // ── 리본 ─────────────────────────────────────────────────────
  'ribbon.close': '패널 닫기',
  'ribbon.needs3d': '3D 해석 전용',
  'ribbon.needsSolve': '먼저 모델을 해석하세요',
  'ribbon.project': '프로젝트',
  'ribbon.resize': '패널 크기 조정',
  'ribbon.selection': '선택',
  'ribbon.settings': '설정',

  // ── 선택 ─────────────────────────────────────────────────────
  'selection.dragNote':
    '왼쪽에서 오른쪽으로 끌면 사각형 안에 완전히 들어온 것만, 오른쪽에서 왼쪽으로 끌면 사각형에 닿은 것까지 선택됩니다.',
  'selection.intro':
    '클릭이나 드래그로 무엇을 고를지, 그리고 Delete가 무엇을 지울지 정합니다. 각 종류는 자기 자신만 가져갑니다. 부재만 쓸어 담아 지우면 절점과 지점, 하중은 그대로 남습니다.',
  'selection.multi': '여러 종류를 한 번에 선택',
  'selection.multiHelp':
    '꺼두면 클릭 한 번에 한 종류만 선택됩니다. 켜면 한 번의 드래그로 절점과 부재를 함께 고를 수 있고, 둘을 한꺼번에 지울 때도 이 방식을 씁니다.',

  // ── 단면 만들기 ──────────────────────────────────────────────
  'shapeBuilder.solid': '중실',
  'shapeBuilder.solidHelp':
    '얇은 벽이 없는 단면입니다. 전단응력은 주라브스키의 포물선 분포를 따르고, 비틀림은 초등적인 닫힌 해가 없습니다. 콘크리트, 목재, 중실 강봉 등 재료와 무관합니다.',
  'shapeBuilder.thin': '박벽',
  'shapeBuilder.thinHelp':
    '단면의 다른 치수에 비해 벽이 얇은 단면입니다. 국부좌굴이 일어나고, 전단은 벽을 따라 흐르며, 비틀림은 생브낭 또는 브레트 이론을 따릅니다. 압연·용접 강재, 냉간성형 강재, 압출 알루미늄 등이 해당합니다.',

  // ── 상태 표시줄 ──────────────────────────────────────────────
  'status.loads': '하중',
  'status.loadsPlural': '하중',
  'status.shells': '판요소',
  'status.shellsPlural': '판요소',

  // ── 단면 응력 ────────────────────────────────────────────────
  'stress.devBody':
    '이 형강의 표에는 공칭 치수가 실려 있고 단면적은 공칭 질량에서 유도되므로, 두 값이 출처에서부터 어긋납니다. 아래 해석은 그려진 외형과 일관되며, 공표된 값과는 다음만큼 차이가 납니다.',
  'stress.devTitle': '공칭 치수',
  'stress.noGeomMsg2':
    '이는 자료가 없어서 생긴 제약일 뿐 단면 자체의 성질이 아닙니다. 형강은 명확히 정의되어 있고, 전체 해석에는 공표된 값이 정상적으로 쓰입니다.',
  'stress.noGeomMsg3':
    'MC를 제외한 모든 카탈로그 계열이 상세 해석을 지원합니다. 그중 하나를 지정하거나, 치수를 직접 입력해 단면을 만드세요.',
  'stress.shearCentre': '전단중심이 도심에서 벗어남',
  'stress.shearCentreMsg':
    '횡하중이 비틀림 없이 단면을 휘게 하려면 이 점을 지나야 합니다. 도심 기준 상대 위치는 다음과 같습니다.',
  'stress.tt.governs': '지배',
  'stress.tt.help':
    '비틀림에는 세 가지 이론이 있고, 각각 다른 종류의 벽에 대해 성립합니다. 한 단면에 두 이론이 동시에 적용될 때 값이 서로 다르며, 그 차이가 곧 박벽 가정의 대가입니다.',
  'stress.tt.na': '해당 없음',
  'stress.tt.title': '세 가지 이론',
  'stress.tt.vsGoverning': '지배값의 {pct}%',

  // ── 2D 전환 ──────────────────────────────────────────────────
  'switch2d.loads': '하중',
  'switch2d.noLoads': '하중 없음',
  'switch2d.noLoadsWarn':
    '이 절단면은 하중을 하나도 가져오지 않습니다. 골조는 풀리지만 모든 결과가 0이 되며, 이는 하중이 없는 구조가 아니라 안전한 구조처럼 보입니다. 절단면이 가져오지 않은 부재에 작용하던 하중은 그 부재와 함께 남습니다.',

  // ── 표 ───────────────────────────────────────────────────────
  'table.derivedFromGeometry': '단면 형상에서 유도된 값입니다. 솔버가 실제로 쓰는 값입니다.',
  'table.showProperties': '단면 특성과 형상 보기',
  'table.torsionUnavailable': '이 단면에는 아직 검증된 비틀림 상수가 없습니다.',
  'toolbar.planeModal.simplified': '부재 단순화됨',

  // ── 뷰포트 ───────────────────────────────────────────────────
  'viewport.barSubdivided': '부재가 분할되었습니다',
  'viewport.clickToPan': '클릭하면 이동 모드로 전환됩니다',
  'viewport.clickToSelect': '클릭하면 선택 모드로 전환됩니다',
  'viewport.jointAdded': '절점 해제를 추가했습니다',
  'viewport.jointRemoved': '절점 해제를 제거했습니다',
  'viewport.modePan': '이동 — 마우스를 끌어 화면을 옮깁니다',
  'viewport.modePan3d': '이동 — 끌면 모델이 회전하고, Shift+끌기로 화면이 이동합니다',
  'viewport.modeSelect': '선택 — 마우스를 끌어 부재를 선택합니다',
  'viewport.selectKindHint': '무엇을 선택할지는 상단 패널의 "선택"에서 정합니다.',
  'viewport.sliderAdded': '미끄럼 절점을 추가했습니다',
  'viewport.sliderRemoved': '미끄럼 절점을 제거했습니다',
  'viewport.switchToPan': '이동으로 전환 — 끌어서 화면을 옮깁니다',
  'viewport.switchToSelect': '선택으로 전환 — 끌어서 선택합니다',
};

export default koExtra;
