# 提交到 App Store

## 一、签名与导出 —— 已经通了

`build/export/AlbumCompact.ipa`（2.6 MB）已经签好并核验过：

| 检查 | 结果 |
|---|---|
| 签名身份 | `Apple Distribution: Xiangyang Shi (LNP5ER743F)` |
| 嵌入描述文件 | `AlbumCompact App Store`，2027-08-27 到期 |
| 是否 App Store 型 | ✅ 无设备列表，`get-task-allow = false` |
| `codesign --verify --deep --strict` | ✅ 通过 |

### 为什么不能用自动签名（这一步卡了很久，值得记下来）

自动签名会让 Xcode 去要一张**云托管（cloud-managed）**发布证书，然后失败：

```
403 FORBIDDEN_ERROR
"You haven't been given access to cloud-managed distribution certificates."
```

误导人的地方在于**这和角色无关**。查 `/v1/users` 返回
`roles: ['ACCOUNT_HOLDER','ADMIN']`、`provisioningAllowed: true` —— 权限已经顶格，
再怎么提权都不会变。

**为什么没被授予 —— 已经查清了，不是账号缺功能。**

云签名在这个账号上是**可用**的，只是走 ASC API key 这条认证路径碰不到它。
证据在同一个账号的另一个 app（ForeignMenu）的已交付 IPA 里，
`embedded.mobileprovision` 含**两张** Apple Distribution 叶证书：

| | 签发时间 | 序列号 | 在 `/v1/certificates` 里 |
|---|---|---|---|
| [0] | 2026-08-27 **08:16:47** | `3144…57BE` | ✅ 有（`TPU3LBPJYQ`） |
| [1] | 2026-08-27 **08:22:24** | `58BD…0C3A` | ❌ **没有** |

两张都是叶证书（issuer 都是 WWDR G3），序列号不同，相隔 5 分半。
[0] 是用户手工签发的；**[1] 是自动签名当时在云端新建的** —— 而它压根不出现在
ASC API 的证书列表里。这和 `DISTRIBUTION_MANAGED` 连合法过滤值都不是
（HTTP 400 `PARAMETER_ERROR.INVALID`）是同一件事的两面：**这个 API 不建模云托管证书。**

⇒ 所以那个 403 既不是角色问题（角色已顶格），也不是账号缺功能（08:22 那张就是反例），
而是 **API key 认证这条路不能用云签名**。云签名要求 Apple ID 账号会话。

### ⚠️ 不要吊销 `F31CF015…`

它是**本机唯一有私钥的** Distribution 证书。吊销它，这台机器就再也签不出
App Store 包（已上传的包不受影响，但如果被拒需要重新出包，就得先重新签发证书）。

另外那张云托管的（08:22 那张）不用管，也不用去清理 —— 它在 API 里看不到，
只有开发者门户网页上能看到。它是否占用 Distribution 配额，没有证据，两边都是猜。

**解法**：用现有证书自己建描述文件，然后手动签名，完全不走云签名。

```bash
# 一次性：用 ASC API 建 App Store 描述文件并装到本地
python3 Tools/asc/mkprofile.py     # 见下面「可复用脚本」
```

`fastlane/ExportOptions.plist` 因此写成 `signingStyle = manual` 并点名证书和
描述文件。导出时**不要**加 `-allowProvisioningUpdates`（加了就又去走云签名）：

```bash
xcodebuild -exportArchive \
  -archivePath build/AlbumCompact.xcarchive \
  -exportOptionsPlist fastlane/ExportOptions.plist \
  -exportPath build/export
```
实测 5.5 秒 `EXPORT SUCCEEDED`。

### 凭据

- Key ID `N3G5466NMU`，私钥在 `~/.appstoreconnect/private_keys/AuthKey_N3G5466NMU.p8`
- Issuer ID `11e1deca-7f34-4781-975a-f4eab3f5d9eb`
  （在 https://appstoreconnect.apple.com/access/integrations/api 页面顶部）
- Transporter.app 已装，所以 `altool` 可用（Xcode 26 自己不再带 iTMSTransporter）

## 二、唯一剩下的阻碍：ASC 里还没有 App 记录

```
altool --validate-app
→ ERROR: Cannot determine the Apple ID from Bundle ID
         'com.xiangyang.albumcompact' and platform 'IOS'. (19)
```

Bundle ID 本身**已注册**（查过：`com.xiangyang.albumcompact`，UNIVERSAL）。
缺的是 App 记录。**App Store Connect API 不支持创建 App 记录**，只能在网页上建：

```
https://appstoreconnect.apple.com/apps
```

建的时候要填：

| 字段 | 填什么 | 注意 |
|---|---|---|
| 平台 | iOS | |
| 名称 | 见下面「先定名字」 | 30 字符上限 |
| 主要语言 | **简体中文** | 源语言是中文 |
| Bundle ID | `com.xiangyang.albumcompact` | 下拉里选，已注册 |
| SKU | 随便一个内部编号，如 `ALBUMCOMPACT001` | 不公开，之后改不了 |
| 用户访问权限 | 完全访问 | |

### ⚠️ 先定名字，再拍截图

名字会出现在导航栏里，所以**改名字等于截图重拍**。而且名字是否可用**只有 ASC 说了算** ——
iTunes 搜索 API 看不到「已预留但未上架」的名字。我查过公开占用情况：

| 候选 | 公开占用 |
|---|---|
| Album Compact | 无同名 |
| AlbumCompact | 无同名 |
| 相册瘦身 | 无同名 |
| 照片瘦身 | 无同名 |
| Photo Compact | 无同名 |

「无同名」不等于「能用」。**先去 ASC 占名成功，再回来改** `CFBundleDisplayName`
和 `fastlane/metadata/*/name.txt`，然后才拍截图。

### 三个文档里查不到的必填字段

| 字段 | 填什么 |
|---|---|
| Copyright | `2026 Xiangyang Shi` —— **不要加 © 符号**，Apple 自己会加 |
| App Review 联系人 | 名、姓、电话、邮箱四项 |
| Content Rights | *是否包含/展示/访问第三方内容* → **否** |

年龄分级问卷七步答完，**没有** AI 相关的题。

## 三、建好 App 记录之后

```bash
# 先校验，别直接传
xcrun altool --validate-app -f build/export/AlbumCompact.ipa -t ios \
  --apiKey N3G5466NMU --apiIssuer 11e1deca-7f34-4781-975a-f4eab3f5d9eb

# 校验过了再上传
xcrun altool --upload-app -f build/export/AlbumCompact.ipa -t ios \
  --apiKey N3G5466NMU --apiIssuer 11e1deca-7f34-4781-975a-f4eab3f5d9eb
```

图标 alpha 通道那个坑（error 90717，只有 Apple 的 validate 会拒）**我们躲过了** ——
图标是代码画的，`sips -g hasAlpha` 查过，1024 原图和归档里的两个尺寸都是 `no`。

## 四、已经准备好的其余部分

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

## 五、App 隐私问卷的答案

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

## 六、审核可能被问到的两件事

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

## 七、提交前最后一遍

- [ ] `CFBundleVersion` 每次上传都要 +1（当前 1）
- [ ] 归档用 Release 配置（DEBUG 代码已验证被排除：`MainThreadWatchdog` /
      `MainThreadBench` / `AssetMetadataProbe` / `seedDemoHistory` 在发布版里均为 0 次）
- [ ] 中英两种语言都实机跑一遍（已做，含英文单复数）
- [ ] 首次启动、拒绝权限、空相册三种状态都不崩
