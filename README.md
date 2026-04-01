# NursingXR_UnityOrganize

이 저장소는 Unity 프로젝트의 자산 인벤토리 생성, 캡처, 품질 검토를 반복 가능하게 수행하기 위한 공용 워크플로우를 공유하는 용도입니다.

핵심 워크플로우는 아래 폴더에 있습니다.

```text
Workflows/
```

레포 루트의 이 README는 "처음 이 저장소를 받은 개발자가 어디부터 읽고 어떻게 시작해야 하는지"를 안내하는 진입 문서입니다.
실제 운영 규칙과 상세 실행 방법은 `Workflows` 아래 문서를 기준으로 봅니다.

## 먼저 읽을 문서

아래 순서대로 읽는 것을 권장합니다.

1. `Workflows/README.md`
2. `Workflows/ProjectAssetInventory/README.md`
3. `Workflows/ProjectAssetInventory/SETUP_GUIDE.md`
4. `Workflows/ProjectAssetInventory/PROMPT_TEMPLATE.md`

## 처음 사용할 AI 프롬프트

다른 개발자나 다른 AI가 이 저장소를 처음 열었을 때는 아래 프롬프트로 시작하면 됩니다.

```text
Workflows\ProjectAssetInventory 를 먼저 꼼꼼히 읽고, 어떤 워크플로우인지 파악해줘.
특히 README.md, SETUP_GUIDE.md, MAINTENANCE.md, PROMPT_TEMPLATE.md, projects.json, projects.local.json 을 우선 확인해줘.
그 다음 현재 작업 환경에 맞게 내가 바로 사용할 프롬프트를 작성해줘.
필요하면 workspace root, workflow root, output label, target projects 중 꼭 필요한 값만 나에게 물어봐줘.
```

## 이 저장소의 역할

이 저장소는 "워크플로우 자체"를 공유하기 위한 저장소입니다.
즉, 아래 항목이 핵심 공유 대상입니다.

- PowerShell 실행 스크립트
- 캡처용 Unity Editor 스크립트
- 설정 파일 템플릿
- 운영 문서
- AI / 개발자용 프롬프트 템플릿

반대로 실제 Unity 프로젝트, 날짜별 산출물 폴더, 임시 캡처 결과물은 개인 작업 환경에 있을 수 있지만 저장소의 핵심 공유 대상은 아닙니다.

## 공유 설정과 로컬 설정

공유 기본값:

```text
Workflows/ProjectAssetInventory/projects.json
```

개인 PC 전용 설정:

```text
Workflows/ProjectAssetInventory/projects.local.json
```

권장 규칙:

- `projects.json`은 팀 공용 기준을 유지합니다.
- `projects.local.json`은 초기 빈 파일만 commit 합니다.
- 이후 각 개발자가 추가한 Unity Editor 경로, 개인 실험 설정, 개인 override는 로컬에만 유지합니다.

## 현재 워크플로우가 하는 일

현재 `ProjectAssetInventory` 워크플로우는 아래 작업을 수행합니다.

- workspace root 아래 Unity 프로젝트를 자동 발견
- 각 프로젝트의 `Assets` 아래 `.fbx`, `.obj`, `.prefab`만 스캔
- 인벤토리 CSV/TXT 생성
- 자산 캡처 이미지 생성
- 품질 감사 수행
- 문제가 있는 파일만 targeted rerun
- 끝까지 자동으로 해결되지 않는 소수 파일은 manual review 또는 manual capture 대상으로 분리

기본 캡처 구도는 우측 상단 대각선이며, 에러가 발생하면 즉시 멈추고 원인 진단 -> 수정 -> 검증 -> 재실행 순서로 진행합니다.

## 레포를 받은 개발자가 보통 하는 일

1. `Workflows/README.md`와 `Workflows/ProjectAssetInventory/README.md`를 읽어 구조를 파악합니다.
2. `projects.local.json`에 자기 PC의 Unity Editor 검색 경로가 필요한지 확인합니다.
3. AI에게 위의 첫 프롬프트를 전달하거나, 직접 `SETUP_GUIDE.md`를 따라 실행합니다.
4. 필요하면 `PROMPT_TEMPLATE.md`를 복사해 현재 작업 환경에 맞게 값만 채웁니다.

## 상세 문서 위치

워크플로우 개요:

```text
Workflows/README.md
Workflows/ProjectAssetInventory/README.md
```

세팅 및 운영 문서:

```text
Workflows/ProjectAssetInventory/SETUP_GUIDE.md
Workflows/ProjectAssetInventory/MAINTENANCE.md
```

프롬프트 템플릿:

```text
Workflows/ProjectAssetInventory/PROMPT_TEMPLATE.md
```

테스트/검증 흐름 참고:

```text
Workflows/ProjectAssetInventory/FINAL_TEST_WORKFLOW.md
```