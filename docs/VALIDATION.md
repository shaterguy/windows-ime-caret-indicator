# Validation Matrix

이 문서는 Windows IME Caret Indicator `v0.1.1`의 실제 확보 증거와 아직 확보하지 못한 요구사항을 구분합니다.

## Identity

- Product version: `v0.1.1`
- Canonical product source: `c67977311d0cb3dc4a709b4c59e3a8245ec6c78d`
- Validation-harness source: `f7f3788a956e8501790b174f5b685aceca0ae9e6`
- Distribution validation run: `35745967759`
- Initial post-release validation harness commit: `97b36a3bbf8945bbc25216b5be24080e1b3245cc`
- Initial post-release validation run: `35801599063` (`success`; target-discovery one-shot WebView2 miss, same-run later high-probe success)
- Resolving exact-identity validation run: `35802437858` (`success`; head `d4635b4df60bebd952c98654fdc782b6e02422ec`)
- Transient-retry validation harness commit: `251fbffcdc3de59b6009e7956850c102f28119bb`
- Release: https://github.com/shaterguy/windows-ime-caret-indicator/releases/tag/v0.1.1

## Requirement-to-evidence matrix

| 영역 | 상태 | 현재 증거 또는 제한 |
|---|---|---|
| 실제 캐럿 기반 표시·마우스 위치 비의존 | PASS | UIA TextPattern2 우선 + Win32 fallback, 실제 입력 대상과 브라우저/Win32 호스트 검증 |
| 한/영 상태 및 전환 | PASS | Microsoft Korean IME 실제 키 입력과 한/영 왕복 검증 |
| ChatGPT 웹 작성창 | PASS | 공개 ChatGPT composer active-caret 진단 |
| Chrome/Edge | PASS | input, textarea, contenteditable |
| 메모장/설정 검색/탐색기 이름 변경 | PASS | 실제 Windows 자동 런타임 검증 |
| Electron/WebView2 | PASS 범위 확보 | Electron은 반복 active-caret 관측. WebView2는 exact `v0.1.1` 제품 소스에서 runs `35745967759`·`35802437858` 및 cross-integrity high probe로 active caret를 직접 관측했습니다. run `35801599063`의 단발 probe false-negative도 보존하며, 검증 하니스는 최대 3회·25ms 간격의 bounded transient re-probe 후에도 실패할 때만 `PRODUCT_CARET_GAP`으로 분류합니다. |
| 입력 비간섭 | PASS 범위 확보 | click-through, focus/foreground preservation, 메시지 동등성 검증 |
| 반응성 | PASS 범위 확보 | 일반 조건 overlay response p95 `68.866 ms` |
| 장시간 안정성 | PASS 범위 확보 | stress/soak 및 단일 overlay 유지 검증 |
| 설치/제거/업데이트 | PASS | Program Files 보호 설치, v0.1.0→v0.1.1 migration, uninstall |
| 관리자 권한 대상 | PASS_WITH_LIMIT | integrity-boundary 접근을 검증했으나 Windows 보안 경계가 허용하지 않는 secure desktop은 의도적 제외 |
| Windows 10/11 x64 client | MISSING | 현재 자동화 x64 호스트는 Windows Server 2025 계열이며 정확한 client OS 수락 근거가 아님 |
| Word/Excel/Outlook | MISSING | 현재 환경에 라이선스된 Microsoft 365 편집 환경이 없음 |
| 실제 DPI 100/125/150/200 | PARTIAL | 실제 100% DPI 호스트와 배치 계산 검증은 있으나 125/150/200 실제 화면은 없음 |
| 혼합 DPI 다중 모니터/음수 좌표 | MISSING | 현재 호스트는 단일 화면이며 실제 다중 디스플레이가 없음 |
| 실제 로그오프/로그인/재부팅 자동 실행 | PARTIAL | HKCU 시작 등록·해제 및 설치/제거 정합성은 확인, 지속형 실제 로그인/재부팅 환경 없음 |
| 전체 캐럿 이동/선택/스크롤 행렬 | PARTIAL | 다수 키보드·마우스 경로는 검증됐으나 요구사항 전체를 동일 수준으로 end-to-end 입증하지 못함 |
| 실제 터치패드 스크롤 | MISSING | GitHub-hosted VM에서 물리 touchpad interaction을 제공하지 않음 |

## 지원 범위 예외

UAC secure desktop, Windows 잠금 화면, 로그인 화면, Winlogon처럼 일반 애플리케이션 접근과 표시가 차단되는 별도 보안 데스크톱은 요구사항 자체에서 지원 범위에서 제외합니다.

## 완료 판정 주의

제품 `v0.1.1` 릴리즈와 배포 identity는 고정되어 있지만, 위 `MISSING`·`PARTIAL` 항목은 실제 환경 증거가 확보되기 전까지 전체 Task의 최종 수락 PASS로 올리지 않습니다.
