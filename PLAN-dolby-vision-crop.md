# 플랜: crop 재인코딩 시 Dolby Vision 8.4 색감 보존

작성: 2026-07-12. 다음 세션에서 이 파일만 읽고 바로 구현 가능하도록 작성됨.

## 문제

- 아이폰 HDR 영상 = Dolby Vision Profile 8.4 (HLG 베이스 + 장면별 RPU 메타데이터).
- 현재 crop 경로(`ReencodeExporter.exportCroppedVideo`)는 `AVAssetExportSession` + videoComposition을 쓰는데, 이 과정에서 **RPU가 소실**되어 출력이 일반 HLG가 됨.
- QuickTime은 원본(DV)엔 Dolby 톤매핑을, 출력(HLG)엔 일반 렌더링을 적용 → 물빠져 보임. 유튜브 업로드 결과도 사용자 확인상 물빠짐.
- 파이프라인 픽셀 값 자체는 정확함을 검증 완료(순수 HLG 소스로 crop 전후 평균 루마 0.0% 차이). 문제는 오직 DV 메타데이터 소실.

## 해법 (Apple 공식 문서 확인됨)

Apple "Incorporating HDR video with Dolby Vision into your apps" (developer.apple.com/av-foundation/ PDF):
- 프레임을 수정하는 편집(crop 등) 후 내보낼 때는 `AVAssetWriter`의 비디오 출력 설정
  `AVVideoCompressionPropertiesKey`에 **`kVTCompressionPropertyKey_HDRMetadataInsertionMode: kVTHDRMetadataInsertionMode_Auto`** 를 지정하면
  인코더(VideoToolbox)가 **Dolby Vision 8.4 메타데이터를 재계산해 삽입**한다.
- 요구사항: 10-bit 픽셀 버퍼(x420), HEVC Main10 프로파일, HLG/BT.2020 색 속성.
- `AVAssetExportSession` 프리셋으로는 이 속성을 줄 수 없음 → **AVAssetReader + AVAssetWriter로 교체 필요**.

## 구현: `Sources/Export/ReencodeExporter.swift`의 `exportCroppedVideo`만 교체

나머지(오디오 무손실 mux, 진행률 콜백 시그니처, EditorView)는 그대로 둔다.

1. **Reader**: `AVAssetReader(asset: composition)` (기존 `EditState.makeComposition(includeAudio: false)` 재사용)
   - `AVAssetReaderVideoCompositionOutput(videoTracks: [track], videoSettings: [pixelFormat: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange])`
   - `.videoComposition` = 기존과 동일한 crop videoComposition (renderSize/transform/색속성 명시 코드 그대로 재사용)
2. **Writer**: `AVAssetWriter(outputURL: tempURL, fileType: .mov)`
   - 비디오 입력 outputSettings:
     ```swift
     [AVVideoCodecKey: AVVideoCodecType.hevc,
      AVVideoWidthKey: pixelCrop.width, AVVideoHeightKey: pixelCrop.height,
      AVVideoColorPropertiesKey: 소스 트랙 포맷 디스크립션에서 읽은 primaries/transfer/matrix (기존 코드 참고),
      AVVideoCompressionPropertiesKey: [
          AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main10_AutoLevel as String,
          kVTCompressionPropertyKey_HDRMetadataInsertionMode as String: kVTHDRMetadataInsertionMode_Auto,
          AVVideoAverageBitRateKey: 소스 videoTrack.load(.estimatedDataRate) 기반 (원본 수준 유지),
      ]]
     ```
   - `expectsMediaDataInRealTime = false`
3. **펌프 루프**: `requestMediaDataWhenReady(on: queue)` + `copyNextSampleBuffer()` append.
   - 진행률 = 샘플 PTS / composition.duration → 기존 `onProgress` 콜백 호출
   - `Task.isCancelled` 체크 시 reader.cancelReading() / writer.cancelWriting() 후 CancellationError throw (기존 취소 UI가 그대로 동작)
   - 완료: input.markAsFinished() → writer.finishWriting()
4. mux 단계(오디오 무손실 복사)는 수정 없음 — temp 영상 파일을 그대로 소비.

주의:
- macOS 27에서 AVAssetWriter 구식 API들이 deprecated 경고를 내지만 정상 동작함. 경고에 끌려 새 API로 갈아타는 데 시간 쓰지 말 것 (프로젝트는 Swift 5 모드, target macOS 15).
- import VideoToolbox 필요 (kVT 상수들).
- 검증 스크립트 작성 시 테스트 소스는 세션 scratchpad의 test_hlg.mov 생성 코드 참고 가능 (verify_hdr.swift — 세션 만료 시 소실, 필요하면 재작성).

## 검증

1. 빌드: `make build`
2. **DV 메타데이터 확인**: 출력 파일 비디오 트랙의 `formatDescriptions` extensions에 Dolby Vision 구성('dvvC' 계열 키)이 있는지 스크립트로 확인. 또는 QuickTime Player ⌘I 인스펙터에 "Dolby Vision"/HDR 표기 확인.
3. **실사용 검증(사용자)**: 실제 아이폰 클립 10~20초를 crop 저장 → QuickTime에서 원본과 나란히 색감 비교 → 문제없으면 유튜브 테스트 업로드.
4. 통과 후 `make app` 설치, git commit.

## 현재 상태

- git: `8df938f` (baseline, 작업 트리 clean)
- 픽셀 검증 결과: HLG 파이프라인은 무결. DV 메타데이터 재생성만 추가하면 됨.
