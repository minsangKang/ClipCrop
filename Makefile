PROJECT := ClipCrop.xcodeproj
SCHEME  := ClipCrop
APP_DIR  = $(shell xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Release -showBuildSettings 2>/dev/null | awk '/ BUILT_PRODUCTS_DIR =/{print $$3}')

.PHONY: app build generate run clean version

# `make version 1.3`처럼 버전을 두 번째 인자로 받는다 — 그 인자가 타깃으로 해석되지 않도록 빈 규칙으로 막는다
ifeq (version,$(firstword $(MAKECMDGOALS)))
  NEW_VERSION := $(word 2,$(MAKECMDGOALS))
  $(eval $(NEW_VERSION):;@:)
endif

# Release 빌드 후 /Applications에 설치
app: build
	rm -rf /Applications/ClipCrop.app
	cp -R "$(APP_DIR)/ClipCrop.app" /Applications/
	@echo "✅ /Applications/ClipCrop.app 설치 완료"

build: generate
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Release build

# 소스 파일 추가/삭제 시 xcodeproj 재생성
generate:
	xcodegen generate

# 설치된 앱 실행
run:
	open /Applications/ClipCrop.app

# 앱 버전 변경: make version 1.3 → CFBundleShortVersionString 교체 + CFBundleVersion(빌드 번호) 1 증가
version:
	@test -n "$(NEW_VERSION)" || { echo "사용법: make version 1.3"; exit 1; }
	@build=$$(awk -F'"' '/CFBundleVersion:/{print $$2}' project.yml); \
	next=$$((build + 1)); \
	sed -i '' -E 's/(CFBundleShortVersionString: )"[^"]*"/\1"$(NEW_VERSION)"/; s/(CFBundleVersion: )"[^"]*"/\1"'"$$next"'"/' project.yml; \
	xcodegen generate >/dev/null; \
	echo "✅ 버전 $(NEW_VERSION) (빌드 $$next)"

clean:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) clean
