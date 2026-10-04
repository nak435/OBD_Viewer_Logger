# 事前準備：自分の Apple Developer チーム ID と、対象端末の CoreDevice ID を調べる
   チーム ID: Xcode > Settings > Accounts、または `security find-identity -v -p codesigning`
   
   端末一覧 : `xcrun devicectl list devices`
   
 以降の <TEAM_ID> / <IPAD_ID> / <IPHONE_ID> は、それぞれ自分の値に置き換えること。

# 1. 署名付きビルド

generic 指定で iPhone / iPad 共通の 1 本

## Releaseビルド
```bash
xcodebuild -project OBD_Viewer_Logger.xcodeproj -scheme OBD_Viewer_Logger \
  -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath build -allowProvisioningUpdates \
  DEVELOPMENT_TEAM=<TEAM_ID> build
```

## Debugビルド
```bash
xcodebuild -project OBD_Viewer_Logger.xcodeproj -scheme OBD_Viewer_Logger \
  -configuration Debug -destination 'generic/platform=iOS' \
  -derivedDataPath build -allowProvisioningUpdates \
  DEVELOPMENT_TEAM=<TEAM_ID> build
```


# 2. Releaseインストール

成果物は Release-iphoneos

## iPad
```bash
xcrun devicectl device install app --device <IPAD_ID> \
  build/Build/Products/Release-iphoneos/OBD_Viewer_Logger.app
```

## iPhone
```bash
xcrun devicectl device install app --device <IPHONE_ID> \
  build/Build/Products/Release-iphoneos/OBD_Viewer_Logger.app
```


# 3. Debugインストール

成果物は Debug-iphoneos

## iPad
```bash
xcrun devicectl device install app --device <IPAD_ID> \
  build/Build/Products/Debug-iphoneos/OBD_Viewer_Logger.app
```

## iPhone
```bash
xcrun devicectl device install app --device <IPHONE_ID> \
  build/Build/Products/Debug-iphoneos/OBD_Viewer_Logger.app
```


# 4. 起動
## iPad
```bash
xcrun devicectl device process launch --device <IPAD_ID> \
  --terminate-existing [--console] com.nak435.OBD-Viewer-Logger
```

## iPhone
```bash
xcrun devicectl device process launch --device <IPHONE_ID> \
  --terminate-existing [--console] com.nak435.OBD-Viewer-Logger
```

## ログ取得
```bash
xcrun devicectl device process launch --device <ID> \
  --terminate-existing --console com.nak435.OBD-Viewer-Logger 2>&1 | tee obd_console.log
```
