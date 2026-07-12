PROJECT := ClipCrop.xcodeproj
SCHEME  := ClipCrop
APP_DIR  = $(shell xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Release -showBuildSettings 2>/dev/null | awk '/ BUILT_PRODUCTS_DIR =/{print $$3}')

.PHONY: app build generate run clean

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

clean:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) clean
