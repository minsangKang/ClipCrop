# ClipCrop

아이폰으로 찍은 Dolby Vision/HDR 영상을 자르고(trim) 크롭(crop)하기 위한 macOS 앱입니다.
크롭이나 모자이크 없이 구간만 자를 때는 원본을 재인코딩하지 않는 **무손실** 내보내기를 쓰고,
크롭·모자이크가 필요할 때만 재인코딩합니다.

## 주요 기능

- **구간 편집**: 재생헤드 위치에서 클립 분리, 구간 삭제, 되돌리기/다시 실행
- **크롭**: 비율 프리셋 선택 후 화면에서 드래그로 위치·크기 조정. 미리보기와 내보내기가 같은
  렌더링 경로를 공유해 화면에서 본 그대로 저장됩니다(WYSIWYG)
- **톤 보정(라이트) 슬라이더 7종**: 노출·하이라이트·그림자·대비·밝기·블랙 포인트·휘도.
  애플 사진 앱의 조정 슬라이더를 최대한 가깝게 흉내낸 것으로, 크롭 후 색이 다소 빠져 보이는
  현상을 눈으로 보면서 보정할 수 있습니다
- **모자이크**: 화면 위 원하는 위치에 블록을 여러 개 추가/삭제. 자유 리사이즈, 이동, 불투명도·
  코너 라운드 조절 가능. 뿌옇게(가우시안 블러) 처리되며 크롭 여부와 무관하게 독립적으로 동작
- **프로젝트 저장/불러오기**: 편집 내용(구간, 크롭 비율/위치)을 JSON으로 저장했다가 나중에
  다시 불러와 이어서 작업 가능
- **여러 영상 동시 편집**: ⌘N으로 새 창을 열면 창마다 독립된 편집 세션이라, 한 창에서
  내보내기가 진행되는 동안 다른 창에서 다른 영상을 편집할 수 있습니다

### 단축키

| 동작 | 단축키 |
| --- | --- |
| 영상 열기 | ⌘O |
| 새 창 열기 | ⌘N |
| 재생/일시정지 | Space |
| 재생헤드에서 클립 분리 | ⌘Y |
| 선택 구간 삭제 | Delete |
| 되돌리기 / 다시 실행 | ⌘Z / ⌘⇧Z |
| 저장(내보내기) | ⌘S |
| 편집 내용 저장 | ⌘⇧S |

## 알려진 제한사항

크롭을 위해 재인코딩하는 과정에서 Dolby Vision의 RPU(장면별 톤매핑) 메타데이터가 소실되어,
출력 영상이 일반 HLG로 재생됩니다. 픽셀 값 자체는 정확하지만 QuickTime 등에서 원본 대비
색이 다소 빠져 보일 수 있습니다 — 톤 보정 슬라이더는 이를 눈으로 맞추기 위한 임시 대응이고,
근본 해결(HEVC 인코더에 DV 메타데이터 재삽입)은 `PLAN-dolby-vision-crop.md`에 정리되어 있습니다.

## 요구 사항

- macOS 15 이상 (실행), Xcode 16 이상 (빌드)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) — `.xcodeproj`는 저장소에 포함되지 않고
  `project.yml`에서 생성합니다

```sh
brew install xcodegen
```

## 설치

```sh
git clone https://github.com/minsangKang/ClipCrop.git
cd ClipCrop
make app
```

`make app`은 `xcodegen generate`로 Xcode 프로젝트를 만들고 Release로 빌드한 뒤
`/Applications/ClipCrop.app`에 설치합니다. 이후 `make run` 또는 Launchpad/Finder에서
바로 실행할 수 있습니다.

### 개발용 빌드

```sh
make build      # xcodegen generate + Release 빌드
make generate    # 소스 파일을 추가/삭제한 뒤 .xcodeproj만 다시 생성
```

Xcode에서 직접 열어 작업하려면 먼저 `make generate`(또는 `xcodegen generate`)로
`ClipCrop.xcodeproj`를 만든 뒤 그 파일을 열면 됩니다.
