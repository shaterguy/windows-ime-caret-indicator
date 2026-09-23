# Windows IME Caret Indicator

Windows의 실제 텍스트 입력 캐럿 옆에 현재 한국어/영어 IME 입력 상태를 표시하는 경량 Windows 상주 유틸리티입니다. 마우스 위치가 아니라 실제 키보드 포커스와 텍스트 캐럿을 추적합니다.

## 현재 정식 버전

- 정식 릴리즈: `v0.1.1`
- 정식 릴리즈 소스: `c67977311d0cb3dc4a709b4c59e3a8245ec6c78d`
- 설치 파일: `WindowsImeCaretIndicator-Setup-0.1.1.exe`
- 포터블 실행 파일: `WindowsImeCaretIndicator.exe`
- 릴리즈: https://github.com/shaterguy/windows-ime-caret-indicator/releases/tag/v0.1.1

정식 `v0.1.1` 태그와 배포 파일은 위 소스 커밋에 고정되어 있습니다. 기본 브랜치에는 릴리즈 이후 문서 및 검증 하니스 정합화 커밋이 추가될 수 있으며, 이 경우에도 `v0.1.1` 제품 소스와 배포 파일은 변경되지 않습니다.

## 표시 의미

텍스트 입력 컨트롤이 실제 키보드 포커스를 가지면 캐럿 근처에 작은 검은색 상자가 표시됩니다.

- `한`: 다음 키 입력이 한국어 IME의 한글 입력 상태로 처리됩니다.
- `영`: 다음 키 입력이 영문/Alphanumeric 상태로 처리됩니다.
- 캐럿이 없어지거나 입력 포커스가 사라지면 표시도 사라집니다.
- 표시창은 캐럿 깜빡임과 무관하게 유지되며 포커스나 마우스 입력을 가로채지 않습니다.

## 구현 구조

- 캐럿 위치: UI Automation 3의 TextPattern2 `GetCaretRange` 우선.
- UI Automation 좌표가 없거나 신뢰하기 어려우면 Win32 `GetGUIThreadInfo` 보완 경로 사용.
- 0길이 UI Automation 범위가 사각형을 주지 않는 공급자는 인접 문자 범위를 최소 확장해 캐럿 모서리를 계산.
- 한/영 상태: 실제 포커스 GUI 스레드의 키보드 레이아웃과 IMM32 상태를 결합해 판정.
- 추적: WinEvent/UI Automation 이벤트 중심, 25ms coalescing과 750ms 저빈도 보정 조회.
- 오버레이: topmost/no-activate/input-transparent 방식.
- DPI/화면 가장자리: 현재 캐럿 높이와 DPI를 반영해 크기·간격을 계산하고 작업 영역 안의 좌상/우상/좌하/우하 후보를 선택.

## 설치

1. GitHub Releases에서 `WindowsImeCaretIndicator-Setup-0.1.1.exe`를 내려받습니다.
2. 설치 프로그램을 실행합니다. 설치는 `Program Files\Windows IME Caret Indicator`에 수행되므로 설치 시 관리자 승인이 필요합니다.
3. 설치 후 프로그램 자체는 일반 사용자 세션에서 동작하며, Windows 로그인 자동 실행은 사용자별 HKCU Run 등록을 사용합니다. 정상 자동 실행 때마다 UAC 승인을 요구하는 구조가 아닙니다.
4. 필요하면 트레이 메뉴에서 **관리자 권한으로 다시 시작**을 선택할 수 있습니다. 이 선택적 동작에는 Windows UAC가 표시될 수 있습니다.

## Windows 시작 시 자동 실행

일반 실행에서 사용자별 `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`의 `WindowsImeCaretIndicator.ProgramFiles` 값으로 등록합니다. 트레이 메뉴의 **Windows 시작 시 자동 실행**에서 켜고 끌 수 있으며 설정은 다음 실행에도 유지됩니다.

실제 로그오프/로그인 또는 재부팅을 포함한 최종 수락 검증은 아직 별도 지속형 Windows 클라이언트 환경이 필요합니다. 현재 자동 검증은 등록·해제·지속 설정과 설치/제거 동작까지 확인했습니다.

## 트레이 메뉴

- **표시 일시 정지**
- **표시 재개**
- **관리자 권한으로 다시 시작** 또는 현재 권한 상태 표시
- **Windows 시작 시 자동 실행**
- **종료**

## 제거

Windows의 설치된 앱 목록에서 **Windows IME Caret Indicator**를 제거하거나 설치 폴더의 제거 프로그램을 실행합니다. 제거 시 현재 제품 identity에 해당하는 사용자별 자동 실행 등록과 사용자 상태가 정리됩니다.

## 지원 대상

- Windows 10 x64
- Windows 11 x64

`.NET 10` Windows Desktop 기반 x64 self-contained 배포입니다. UAC 보안 데스크톱, 잠금/로그인 화면, Winlogon 등 일반 애플리케이션 접근이 차단되는 별도 보안 데스크톱은 지원 범위에서 제외합니다.

## 검증 현황

`v0.1.1` 배포 파일은 canonical product source `c67977311d0cb3dc4a709b4c59e3a8245ec6c78d`와 validation-harness source `f7f3788a956e8501790b174f5b685aceca0ae9e6`을 기준으로 자동 검증·릴리즈되었습니다. 릴리즈 후 기본 코드선에서도 정식 제품 소스는 계속 `c67977311d0cb3dc4a709b4c59e3a8245ec6c78d`로 고정했습니다. Windows CI run `35801599063`은 전체 run은 `success`였지만 WebView2 target-discovery의 단발 UI Automation probe에서 `activeCaret=false`를 한 차례 관측했고, 같은 run의 이후 cross-integrity high probe에서는 `activeCaret=true`를 다시 확인했습니다. 이어진 exact-identity run `35802437858`(head `d4635b4df60bebd952c98654fdc782b6e02422ec`)에서도 WebView2 active caret가 재확인되었습니다. 이후 validation-harness commit `251fbffcdc3de59b6009e7956850c102f28119bb`은 이 transient provider-readiness 변동을 숨기지 않고 최대 3회·25ms 간격의 bounded re-probe로 다루도록 보강했습니다. 이 후속 검증·하니스 변경은 정식 `v0.1.1` 제품 소스, 태그, 배포 파일을 바꾸지 않습니다. 대표 검증에는 다음이 포함됩니다.

- 메모장, Windows 설정 검색, 파일 탐색기 이름 변경 입력.
- Chrome/Edge의 input, textarea, contenteditable.
- 공개 ChatGPT 웹 작성창의 실제 활성 캐럿.
- Microsoft Korean IME 실제 키 입력과 한/영 전환.
- Electron 기반 테스트 호스트와 WebView2 기반 테스트 호스트.
- 오버레이 클릭 통과, 포커스/포그라운드 비간섭, 스트레스/장시간 실행과 단일 오버레이 유지.
- 일반 조건에서 오버레이 갱신 p95 `68.866 ms`.
- Program Files 보호 설치, `v0.1.0 → v0.1.1` 정식 업데이트/마이그레이션, 제거.
- x64 self-contained 실행 파일과 설치 프로그램의 배포 무결성.

현재 자동 검증의 실제 x64 호스트는 GitHub-hosted Windows Server 2025 계열입니다. 아래 항목은 요구된 실제 환경을 현재 자동화 환경이 제공하지 못해 아직 최종 수락 근거가 없습니다.

- Windows 10/11 x64 클라이언트 자체에서의 전체 수락 시험.
- 정식 라이선스 Microsoft Word 본문, Excel 셀 직접 편집/수식 입력줄, Outlook 메일 작성창.
- 실제 125%/150%/200% DPI, 혼합 DPI 다중 모니터, 음수 좌표 모니터 배치.
- 실제 로그오프/로그인 또는 재부팅 후 자동 실행.
- 실제 터치패드 스크롤을 포함한 요구사항 전체 입력 동작 행렬.

세부 증거와 미검증 범위는 [docs/VALIDATION.md](docs/VALIDATION.md)에 정리합니다.

## 배포 파일 SHA-256

- `WindowsImeCaretIndicator-Setup-0.1.1.exe`: `67c384a9f2da155dc59217acb87e036130d0e842131b0a2519c98b8dc56cb30b`
- `WindowsImeCaretIndicator.exe`: `0ed41403a2ad4745a61ed75014502bf38cd2ce5c1dffdb10d7b3cf1a50561f69`

## 알려진 제한

Windows 앱·컨트롤 구현과 무결성 수준에 따라 UI Automation 또는 Win32 캐럿 정보 접근이 제한될 수 있습니다. 일반 사용자 데스크톱에서의 상주 사용을 대상으로 하며, 운영체제가 일반 앱의 접근 또는 표시를 차단하는 보안 데스크톱은 지원하지 않습니다. 관리자 권한 대상 앱은 Windows 보안 경계가 허용하는 범위에서 지원하며, 필요 시 사용자가 트레이 메뉴에서 프로그램을 관리자 권한으로 다시 시작할 수 있습니다.
