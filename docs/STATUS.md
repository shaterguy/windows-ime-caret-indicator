# Windows IME Caret Indicator 상태

## 정식 릴리즈

- 현재 정식 버전: `v0.1.1`
- canonical product source: `c67977311d0cb3dc4a709b4c59e3a8245ec6c78d`
- validation-harness source: `f7f3788a956e8501790b174f5b685aceca0ae9e6`
- initial post-release validation harness commit: `97b36a3bbf8945bbc25216b5be24080e1b3245cc`
- initial post-release validation run: `35801599063` (`success`; WebView2 target-discovery one-shot miss disclosed below)
- resolving exact-identity validation run: `35802437858` (`success`; head `d4635b4df60bebd952c98654fdc782b6e02422ec`)
- transient-retry validation harness commit: `251fbffcdc3de59b6009e7956850c102f28119bb`
- GitHub Release: https://github.com/shaterguy/windows-ime-caret-indicator/releases/tag/v0.1.1
- 배포 검증 GitHub Actions run: `35745967759`
- installer SHA-256: `67c384a9f2da155dc59217acb87e036130d0e842131b0a2519c98b8dc56cb30b`
- portable SHA-256: `0ed41403a2ad4745a61ed75014502bf38cd2ce5c1dffdb10d7b3cf1a50561f69`

`v0.1.1` 태그와 릴리즈 자산은 위 canonical source에 고정하며 릴리즈 후 문서 정합화 때문에 retarget·replace하지 않습니다.

WebView2 증거는 변동을 숨기지 않고 해석합니다. run `35801599063`은 전체 workflow가 `success`였지만 target-discovery의 첫 단발 UI Automation probe에서 active caret를 놓쳤습니다. 같은 run의 이후 cross-integrity high probe와 후속 exact-identity run `35802437858`에서는 active caret가 다시 확인되어 재현 가능한 제품 결함으로 보지 않습니다. 현재 검증 하니스는 이 transient provider-readiness 변동에 대해 최대 3회·25ms 간격의 bounded re-probe를 사용하며, 기존 단발 miss 자체도 증거에서 제거하지 않습니다.

## 재사용 가능한 통과 증거

- Notepad, Windows Settings search, Explorer rename.
- Chrome/Edge input·textarea·contenteditable.
- 공개 ChatGPT 웹 작성창 active caret.
- 실제 Microsoft Korean IME 입력/전환.
- deterministic Electron host, WebView2 host.
- click-through, foreground/focus preservation.
- overlay response p95 `68.866 ms`.
- stress/soak/single-overlay.
- protected Program Files install/uninstall, v0.1.0→v0.1.1 migration, integrity-boundary checks.

## 아직 닫히지 않은 필수 실제 환경 검증

1. Windows 10/11 x64 client 자체에서의 최종 수락.
2. 라이선스된 Word 본문, Excel 셀 직접 편집·수식 입력줄, Outlook 작성창.
3. 실제 100/125/150/200% DPI와 혼합 DPI 다중 모니터 이동, 음수 좌표 배치. 현재 실제 호스트는 단일 100% DPI 화면만 제공합니다.
4. 실제 로그오프/로그인 또는 재부팅 후 자동 실행 및 끄기/다시 켜기.
5. 요구사항에 열거된 전체 캐럿 이동·선택·스크롤 비간섭 행렬 중 아직 실제 end-to-end 증거가 없는 항목, 특히 실제 터치패드 스크롤.

위 공백은 현재 GitHub-hosted x64 환경과 연결 도구가 요구된 물리/라이선스 환경을 제공하지 못해서 남아 있습니다. Windows Server/ARM64/가상 좌표 계산/레지스트리 존재만으로 해당 항목을 PASS로 대체하지 않습니다.

## 제품 상태와 문서 계보

정식 배포 제품 identity는 계속 `v0.1.1 @ c67977311d0cb3dc4a709b4c59e3a8245ec6c78d`입니다. 기본 브랜치가 이 커밋의 문서 또는 검증 하니스 전용 descendant로 이동하더라도 제품 소스·태그·릴리즈 자산 identity는 변경되지 않습니다.
