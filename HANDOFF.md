# 交接：把 Album Sweeper 传上 App Store

> 面向接手这件事的 agent。读完这一页就够，不需要翻聊天记录。
> 最后更新 2026-08-28。仓库 https://github.com/chuanbei2026/album-compact

## 0. 一句话现状

**包已签好、已通过 Apple 官方校验，App 记录已建好。剩下的是上传 + 在网页上补三件东西。**

```
xcrun altool --validate-app …  →  VERIFY SUCCEEDED with no errors
```

## 1. 这个 app 是什么

iPhone + iPad 通用，清理相册。三件事决定了它的设计，改任何东西前先理解：

1. **只有像素完全一致的重复，才允许「不看就清」**（默认打勾）。
   其余一律让用户看大图再决定，而且可以一次留好几张。
   这是产品的立身之本 —— 同赛道 12 个 app 都在卖「一键全清」，它卖「不误删」。
2. **零上传，可核验。** 发布二进制里七个联网符号计数全为 0，连 CFNetwork
   都没链。这不是声明，是能在产物上跑命令验证的事实（见 §5）。
3. **分类主干是神经网络。** 冻结的 Apple Vision FeaturePrint + 每类一个
   逻辑回归头，在设备上学。手写规则只留作冷启动先验；地图/网页/其他三类
   **只有头、没有规则**（用户明确否掉了用蓝绿色判断地图这种启发式）。

## 2. 名字（已定，别再改）

| | 值 | 在哪 |
|---|---|---|
| 中文名 | **相册减负** | `CFBundleDisplayName`（zh-Hans）、`fastlane/metadata/zh-Hans/name.txt` |
| 英文名 | **Album Sweeper** | 同上（en）、`en-US/name.txt`。**ASC 上 App 记录就叫这个** |
| Bundle ID | `com.xiangyang.albumcompact` | 历史遗留，和名字不一致是正常的，别动 |
| SKU | `album_sweep_001` | 建记录时定的，改不了 |

⚠️ 改名意味着重新归档 + 重拍全部截图（名字在导航栏里）。不要改。

历史：原名 `相册瘦身` 被深圳美因网络科技占用（`com.albumcleaner.app`，在架）。
`Album Sweep` 在 ASC 被拒（iTunes 搜索显示「无同名」但 ASC 才是终审 —— 这条教训值钱），
于是定为 `Album Sweeper`。

## 3. 立刻能做的：上传

```bash
cd ~/Desktop/workplace/album_compact
export ASC_KEY_ID=N3G5466NMU
export ASC_ISSUER_ID=<问用户，或见 ASC → 用户和访问 → 集成 页面顶部>

xcrun altool --upload-app -f build/export/AlbumCompact.ipa -t ios \
  --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"
```

私钥在 `~/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8`，已在位。
Transporter.app 已装（Xcode 26 自己不带 iTMSTransporter，没装的话 altool 会
报 `Defaults.properties` 打不开）。

如果包需要重建：

```bash
xcodegen generate                      # project.yml 改过才需要
xcodebuild -project AlbumCompact.xcodeproj -scheme AlbumCompact \
  -destination 'generic/platform=iOS' -configuration Release \
  -archivePath build/AlbumCompact.xcarchive archive
xcodebuild -exportArchive -archivePath build/AlbumCompact.xcarchive \
  -exportOptionsPlist fastlane/ExportOptions.plist -exportPath build/export
```

⚠️ **不要加 `-allowProvisioningUpdates`，不要改成自动签名。** 原因见 §6。
⚠️ 每次重新上传都要把 `CFBundleVersion` +1（当前 1，在 `project.yml`）。

## 4. 还差的三件事（都在网页上做，API 做不了）

### ① 加简体中文本地化 —— 必须做

ASC 上目前**只有 `en-US`**，主语言也是 `en-US`。所以中文用户现在会看到英文名。
去 App Store Connect → 该 App → 左上语言下拉 → 添加**简体中文**，把
`fastlane/metadata/zh-Hans/` 里的六个字段填进去。

两边的文案都已经写好并核对过字数上限：

```
fastlane/metadata/{en-US,zh-Hans}/
  name.txt  subtitle.txt  keywords.txt
  promotional_text.txt  description.txt  release_notes.txt
```

### ② 三个文档里查不到格式的必填字段

| 字段 | 填什么 |
|---|---|
| Copyright | `2026 Xiangyang Shi` —— **不要加 © 符号**，Apple 自己会加 |
| App Review 联系人 | 名、姓、电话、邮箱四项 |
| Content Rights | *是否包含/展示/访问第三方内容* → **否** |

年龄分级问卷七步答完，**没有** AI 相关的题。分级填 **4+**
（无用户生成内容、无社交、无网络、无广告）。

### ③ 上架截图 —— 还没拍

需要 6.9" iPhone（1320×2868）和 13" iPad（2064×2752），中英各一套。

```bash
./fastlane/screenshots/capture.sh <一个装着演示照片的文件夹>
```

⚠️ **绝对不要用用户的真实相册拍上架截图** —— 那些图会公开。
需要先造一批合成演示照片（之前那批在临时目录被清掉了）。
脚本会自动导入模拟器相册、修 TCC 授权、按中英各拍 5 个界面。

模拟器授权有个坑：`xcrun simctl privacy grant` 写的 TCC 行 iOS 26 会忽略
（它写 `auth_reason=4, auth_version=1`，真人点击产生的是 `2/2`）。
脚本里已经带了直接改 sqlite 的补丁，别删。

## 5. App 隐私问卷：全部答「否」，而且可核验

| 问题 | 答案 | 依据 |
|---|---|---|
| 是否收集数据 | **否** | 二进制里联网符号计数为 0 |
| 是否用于追踪 | **否** | 同上 |
| 第三方 SDK | **无** | 只链接 Apple 系统框架 |
| 出口合规（是否使用加密） | **否** | `ITSAppUsesNonExemptEncryption = false` 已在 Info.plist |

```bash
BIN=build/AlbumCompact.xcarchive/Products/Applications/AlbumCompact.app/AlbumCompact
otool -L "$BIN"   # 全集：Accelerate BackgroundTasks Charts CoreFoundation
                  # CoreGraphics Foundation ImageIO Photos SwiftUI UIKit
                  # UserNotifications Vision —— 没有一个能联网
for s in URLSession NSURLConnection CFNetwork nw_connection CFSocket \
         getaddrinfo SCNetworkReachability; do
  echo "$s $(nm -u "$BIN" | grep -ci $s)"        # 全部 0
done
for s in MainThreadWatchdog MainThreadBench AssetMetadataProbe \
         seedDemoHistory demoRoute; do
  echo "$s $(strings -a "$BIN" | grep -c $s)"    # DEBUG 代码，全部 0
done
```

`PrivacyInfo.xcprivacy` 已随包发出：无追踪、无收集、无需申报的 API。

## 6. 签名：为什么必须手动，别「优化」成自动

自动签名在这个账号上**走不通**。它会去要一张**云托管**发布证书然后 403：

```
403 FORBIDDEN_ERROR
"You haven't been given access to cloud-managed distribution certificates."
```

最误导人的地方：**和角色无关**。`/v1/users` 返回
`roles: ['ACCOUNT_HOLDER','ADMIN']`、`provisioningAllowed: true`，已经顶格。
真正的原因是 **ASC API key 这条认证路径碰不到云签名**（云签名要求 Apple ID
账号会话）—— 证据是同一账号另一个 app 的已交付包里有两张 Distribution 叶证书，
`08:16:47`（手工签发）和 `08:22:24`（自动签名当时在云端新建的）。

**而且 `/v1/certificates` 不列举云托管证书**（`DISTRIBUTION_MANAGED` 连合法
过滤值都不是，HTTP 400）。所以**不要用 ASC API 判断「有没有云证书」** ——
我因此下过一个错误结论。要看只能去开发者门户网页。

解法就是现在这样：现有证书 + 自建描述文件 + `signingStyle = manual`，
5.5 秒出包。描述文件是 `AlbumCompact App Store`，UUID
`51a5ebf6-08a6-4083-bbf1-4898cbba80bc`，2027-08-27 到期。要重建：

```bash
export ASC_KEY_ID=… ASC_ISSUER_ID=…
python3 Tools/asc/asc.py          # 先看现状
python3 Tools/asc/mkprofile.py    # 建并装到本地
```

### ⚠️ 绝对不要吊销 `F31CF015…`

它是**本机唯一有私钥的** Distribution 证书。吊销它，这台机器就再也签不出
App Store 包（已上传的不受影响，但被拒后重出包得先重新签发证书）。
账号上另有一张云托管的（`0A169348…`，08:22 那张），不用管、不用清理。

## 7. 审核可能被问到的一处

`AlbumCompact/Photos/PhotoLibraryService.swift` 用了一处非公开 KVC 取文件体积
（`r.value(forKey: "fileSize")`）—— PhotoKit 没有公开的文件体积 API。三点事实：

- **有兜底**：取不到就按尺寸估算，功能不会崩
- **估算够准**：真机 12,930 张上，估算 3.73 GB vs 精确 3.75 GB，差 **0.5%**
- **静态扫描发现不了**：该字符串只有 8 字节，命中 Swift small-string 优化，
  不进二进制字符串表（实测发布版里 `strings | grep -x fileSize` 计数为 0）

用户还没决定留不留。要彻底避开就删掉那段只用估算 —— 聚合数字影响 0.5%，
单张 HEIC/ProRAW 偏差会大些。**不要擅自删，问用户。**

## 8. 别踩的坑（都是实测踩过的）

| 坑 | 结论 |
|---|---|
| `git init` 默认分支 | 这台机器上是 `master`，推 `main` 会 `src refspec` 失败 |
| GitHub 推送 401/404 | 个人号必须用 `git@github-personal:` 别名（`gh` 活跃账号是公司号时看不见私有仓库，报的是 404 不是 403） |
| `gh` 账号 | App 项目用 `chuanbei2026`，用完 `gh auth switch -u xiangyang-luma` 切回 |
| 模拟器跑 Vision | `VNGenerateImageFeaturePrint` / `VNClassifyImage` 在模拟器上永远失败（无神经引擎）。**绝不要把多个 Vision 请求放进同一个 `perform`** —— 一个失败会连坐，静默毁掉 OCR |
| 中文 OCR | `recognitionLevel = .fast` 是拉丁文专用，中文几乎读不出来。必须 `.accurate` |
| `Text(变量)` | 不本地化。模型层的计算属性要用 `String(localized:)` 包 |
| 英文单复数 | 中文源串没有复数，英文必须补 `variations`（否则出现「Clear 1 groups」） |
| `hasAdjustments` | 未取 `PHAssetResource` 时返回 `false`，**绝不要退回用 `modificationDate` 猜** —— 那个改动曾让候选从 9,859 掉到 3,892 |
| 元数据慢 | 别对每张照片调 `PHAssetResource.assetResources(for:)`（真机 20.2s → 1.6s，只对视频取） |

## 9. 关键文件

```
fastlane/SUBMISSION.md          提交清单（比本页更细）
fastlane/ExportOptions.plist    手动签名配置，别改成 automatic
fastlane/metadata/              两种语言各六个字段，已核对上限
fastlane/screenshots/capture.sh 截图脚本
Tools/asc/                      ASC API 小工具（探查 / 建描述文件）
Tools/AlgoLab/                  算法实验台（macOS CLI，链接 app 的 Core 源码）
docs/screenshots/               审核会遇到的边界状态实拍存档
README.md                       853 行，每个架构决定和实测数字
```

## 10. 交接时的状态

| 项目 | 状态 |
|---|---|
| 归档 | ✅ `ARCHIVE SUCCEEDED`，v1.0 build 1 |
| 导出 | ✅ `EXPORT SUCCEEDED`，`build/export/AlbumCompact.ipa` 2.6 MB |
| 签名核验 | ✅ Apple Distribution / 无设备列表 / `get-task-allow=false` / `codesign --verify --deep --strict` 通过 |
| **Apple 官方校验** | ✅ **`VERIFY SUCCEEDED with no errors`** |
| ASC App 记录 | ✅ `Album Sweeper`，1.0 处于 `PREPARE_FOR_SUBMISSION` |
| 上传 | ❌ **没做** —— 这是你的第一步 |
| 简体中文本地化 | ❌ 没加 |
| 上架截图 | ❌ 没拍（缺演示素材） |
| 边界状态 | ✅ 拒绝权限 / 空相册 / 首启 都不崩，实拍在 `docs/screenshots/` |
