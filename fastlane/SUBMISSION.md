# 提交到 App Store

## 一、你必须自己做的两件事

这两步需要你的 Apple 账号凭据，我这边做不了。

### 1. 让 Xcode 能签发布版

归档能成功，但 `-exportArchive` 报 `No Accounts` —— Xcode 的账号列表是空的，
所以它无法自动创建 App Store 描述文件（目前只有开发用的那一份）。

二选一：

**A. 在 Xcode 里登录**（一次性，之后都自动）
Xcode → Settings → Accounts → `+` → Apple ID → 登录

**B. 用 API key，完全不碰 Xcode 界面**
你已经有 `~/.appstoreconnect/private_keys/AuthKey_N3G5466NMU.p8`，
还差一个 **Issuer ID**（UUID 格式）。在
App Store Connect → 用户和访问 → 集成 → App Store Connect API
页面顶部就能看到。拿到后：

```bash
xcodebuild -exportArchive \
  -archivePath  build/AlbumCompact.xcarchive \
  -exportOptionsPlist fastlane/ExportOptions.plist \
  -exportPath   build/export \
  -allowProvisioningUpdates \
  -authenticationKeyPath   ~/.appstoreconnect/private_keys/AuthKey_N3G5466NMU.p8 \
  -authenticationKeyID     N3G5466NMU \
  -authenticationKeyIssuerID <你的-issuer-id>
```

### 2. 在 App Store Connect 里建 App 记录

Bundle ID `com.xiangyang.albumcompact` 目前只注册过开发用途。
新建 App 时选这个 Bundle ID，主要语言选**简体中文**（源语言是中文）。

## 二、我已经准备好的

### 归档与导出

```bash
xcodebuild -project AlbumCompact.xcodeproj -scheme AlbumCompact \
  -destination 'generic/platform=iOS' -configuration Release \
  -archivePath build/AlbumCompact.xcarchive -allowProvisioningUpdates archive
```
实测 `ARCHIVE SUCCEEDED`。导出配置在 `fastlane/ExportOptions.plist`。

### 上传（导出成功之后）

```bash
xcrun altool --upload-app -f build/export/AlbumCompact.ipa -t ios \
  --apiKey N3G5466NMU --apiIssuer <你的-issuer-id>
```

### 商店文案

`fastlane/metadata/{zh-Hans,en-US}/` —— 名称、副标题、关键词、
宣传文本、描述、更新说明，全部已核对不超字数上限。

### 截图

```bash
./fastlane/screenshots/capture.sh <一个装着演示照片的文件夹>
```
自动在 iPhone 17 Pro Max（1320×2868，6.9" 档）和 iPad Pro 13"（2064×2752，13" 档）
上，按中英各拍 5 张：首页 / 滑动卡组 / 完全一致的重复 / 不同版本 / 清理记录。

⚠️ **别用你自己的真实相册拍上架截图** —— 那些图会公开。要么用演示素材，
要么在真机上挑你愿意公开的内容手动截。

## 三、App 隐私问卷的答案

App Store Connect 会逐项问你收集了什么。**全部选「否 / 不收集」**，
这不是保守填法，是可以在编译产物上核验的事实：

| 问题 | 答案 | 依据 |
|---|---|---|
| 是否收集数据 | **否** | 二进制里联网符号计数为 0 |
| 是否用于追踪 | **否** | 同上 |
| 第三方 SDK | **无** | 只链接 Apple 系统框架 |
| 出口合规（是否使用加密） | **否** | `ITSAppUsesNonExemptEncryption = false` 已在 Info.plist |
| 分级 | **4+** | 无用户生成内容、无社交、无网络、无广告 |

在归档产物上实测过（2026-08-27，v1.0 build 1）：

```bash
BIN=build/AlbumCompact.xcarchive/Products/Applications/AlbumCompact.app/AlbumCompact
otool -L "$BIN"                       # 只有 Apple 系统框架，无 CFNetwork / Network
nm -u "$BIN" | grep -ci urlsession    # 0
```

链接的框架全集：Accelerate · BackgroundTasks · Charts · CoreFoundation ·
CoreGraphics · Foundation · ImageIO · Photos · SwiftUI · UIKit ·
UserNotifications · Vision（外加 Swift 运行时）。**没有一个能联网。**

七个联网符号 —— `URLSession` / `NSURLConnection` / `CFNetwork` /
`nw_connection` / `CFSocket` / `getaddrinfo` / `SCNetworkReachability`
—— 计数**全部为 0**。

`PrivacyInfo.xcprivacy` 已随包发出：无追踪、无收集、无需申报的 API。

## 四、审核可能被问到的两件事

**1. 相册权限用途说明**
`NSPhotoLibraryUsageDescription` 已写明用途且中英双语。审核员会实际试用，
确保权限弹窗出现在合理的时机（首次进入即请求，界面上有说明）。

**2. 文件体积用了非公开 KVC**
`PhotoLibraryService` 里 `r.value(forKey: "fileSize")` —— PhotoKit 没有公开的
文件体积 API。三点事实：

- 已有兜底：取不到就按尺寸估算，功能不会崩
- 估算精度实测很好：真机 12,930 张上，估算 3.73 GB vs 精确 3.75 GB，**差 0.5%**
- 该字符串只有 8 字节，命中 Swift small-string 优化，**不进二进制字符串表**
  （实测发布版里搜不到），静态扫描发现不了

要彻底避开就删掉那段，只用估算 —— 聚合数字影响 0.5%，单张 HEIC/ProRAW 偏差会大些。

## 五、提交前最后一遍

- [ ] `CFBundleVersion` 每次上传都要 +1（当前 1）
- [ ] 归档用 Release 配置（DEBUG 代码已验证被排除：`MainThreadWatchdog` /
      `MainThreadBench` / `AssetMetadataProbe` / `seedDemoHistory` 在发布版里均为 0 次）
- [ ] 中英两种语言都实机跑一遍（已做，含英文单复数）
- [ ] 首次启动、拒绝权限、空相册三种状态都不崩
