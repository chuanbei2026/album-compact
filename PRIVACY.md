# Privacy Policy · 隐私政策

**Album Sweeper / 相册减负**
Last updated 2026-08-28 · 最后更新 2026-08-28

---

## English

### Album Sweeper collects nothing

Album Sweeper does not collect, transmit, store, or share any personal data.
There is no analytics, no crash reporting, no advertising, no tracking, and no
third-party SDK of any kind. No account is required and none can be created.

### This is verifiable, not just a promise

The app links no networking framework at all. Anyone can check this on the
shipped binary:

```bash
otool -L Album\ Sweeper.app/Album\ Sweeper
```

The complete list of linked frameworks is Accelerate, BackgroundTasks, Charts,
CoreFoundation, CoreGraphics, Foundation, ImageIO, Photos, SwiftUI, UIKit,
UserNotifications and Vision, plus the Swift runtime. `CFNetwork` and
`Network.framework` are absent. Not one of those frameworks can open a
connection.

Seven networking symbols were checked against the release build and every count
is zero: `URLSession`, `NSURLConnection`, `CFNetwork`, `nw_connection`,
`CFSocket`, `getaddrinfo`, `SCNetworkReachability`.

A privacy manifest (`PrivacyInfo.xcprivacy`) ships inside the app declaring no
tracking, no collected data types, and no APIs requiring declared reasons.

### What the app does with your photos

Album Sweeper needs access to your photo library because finding duplicates and
clutter requires reading the photos themselves. All of that reading and all of
the analysis happens on your device:

- **Fingerprints.** Small perceptual hashes (dHash and pHash) are computed from
  a downscaled copy of each photo, in memory, to find duplicates.
- **On-device inference.** Apple's Vision framework runs text recognition and
  produces image feature vectors on the Neural Engine. These never leave the
  device.
- **On-device learning.** When you name a group of screenshots, a small
  classifier is trained locally so similar screenshots are recognised later.
  Both the training data and the resulting model stay in the app's own storage.
- **Caches.** Fingerprints, feature vectors and your decisions are cached in the
  app's private container so a rescan is fast. Deleting the app removes them.

Nothing above is uploaded anywhere. There is no server to upload to.

### Deleting photos, and what the app writes back

Album Sweeper never deletes anything without your confirmation. Swiping a photo
away only **marks** it; marked items sit in a pending list inside the app.

You can set a grace period before marked items are actually removed. It is worth
being precise about what that does, because the app deliberately does not
pretend to more power than iOS gives it: **a third-party app cannot run code
days later to delete your files.** During the grace period the items simply wait
in the pending list, and you come back and execute the removal yourself. The
app says this on screen rather than implying a timer is running.

Two optional settings write to your photo library, which is why the app asks for
add permission as well as read permission:

- **"Also add to a 'To delete' album"** creates an album in Photos and puts the
  marked items in it, so you can look them over outside this app.
- **"Hide from library while pending"** sets the marked items as hidden, so they
  are out of your main library while they wait. This is reversible.

The actual deletion goes through Apple's Photos framework
(`PHAssetChangeRequest.deleteAssets`) — a single call site in the whole app.
iOS itself then asks you to approve the removal; the app cannot bypass that
prompt. Approved items go to **Recently Deleted**, where iOS keeps them for 30
days.

### Children

The app has no user-generated content, no social features, no network access and
no advertising. It is rated 4+.

### Changes

If this policy ever changes, the updated version will appear at this URL and the
date above will change. Since the app collects nothing, no change can
retroactively affect data that was never gathered.

### Contact

Questions or reports: https://github.com/chuanbei2026/album-compact/issues

---

## 简体中文

### 相册减负不收集任何数据

相册减负不收集、不传输、不存储、不共享任何个人数据。没有统计分析,没有崩溃上报,
没有广告,没有追踪,也没有任何第三方 SDK。不需要账号,也无法注册账号。

### 这一点可以核验,不只是承诺

这个 app **没有链接任何联网框架**。任何人都可以在发布产物上自己检查:

```bash
otool -L 相册减负.app/相册减负
```

链接的框架全集是 Accelerate、BackgroundTasks、Charts、CoreFoundation、
CoreGraphics、Foundation、ImageIO、Photos、SwiftUI、UIKit、UserNotifications、
Vision,外加 Swift 运行时。`CFNetwork` 和 `Network.framework` **都不在其中**。
这些框架里没有一个能建立网络连接。

七个联网符号在发布版上逐一检查,计数**全部为 0**:`URLSession`、
`NSURLConnection`、`CFNetwork`、`nw_connection`、`CFSocket`、`getaddrinfo`、
`SCNetworkReachability`。

app 内随包发出隐私清单(`PrivacyInfo.xcprivacy`),声明:无追踪、无收集的数据
类型、无需要申报理由的 API。

### app 拿你的照片做什么

相册减负需要访问相册,因为找出重复和杂物必须读到照片本身。所有读取和所有分析
都发生在你的设备上:

- **指纹。** 从每张照片的缩小副本在内存里算出很小的感知哈希(dHash 和 pHash),
  用来找重复。
- **设备端推理。** 用 Apple 的 Vision 框架在神经引擎上做文字识别、生成图像特征
  向量。这些**不会离开设备**。
- **设备端学习。** 当你给一簇截图命名时,会在本地训练一个很小的分类器,以后遇到
  相似截图就能认出来。训练数据和训练出的模型都留在 app 自己的存储里。
- **缓存。** 指纹、特征向量和你的决定会缓存在 app 的私有容器里,这样重新扫描
  很快。删除 app 会一并清除。

以上没有任何一项会被上传到任何地方 —— 因为没有可上传的服务器。

### 关于删除照片,以及 app 会写回什么

相册减负**不会在未经你确认的情况下删除任何东西**。把照片滑走只是**标记**,
被标记的照片留在 app 内的待删清单里。

你可以设置一个缓冲期。这里要讲准确,因为这个 app 刻意不假装自己有 iOS 没给的
权力:**第三方 app 无法在几天之后运行代码来删除你的文件。** 缓冲期内照片只是
留在待删清单里等着,由你回来自己执行删除。app 会在界面上把这件事说清楚,而不是
暗示有个定时器在跑。

有两个可选设置会**写入**你的相册 —— 这也是 app 除了读取权限之外还要请求添加
权限的原因:

- **「同时放进『待删』相簿」** 会在「照片」里建一个相簿,把标记的照片放进去,
  方便你在这个 app 之外过一遍。
- **「待删期间从相册隐藏」** 会把标记的照片设为隐藏,等待期间不出现在主相册里。
  这个操作可逆。

真正的删除通过 Apple 的 Photos 框架执行(`PHAssetChangeRequest.deleteAssets`,
整个 app 里只有一个调用点)。之后由 **iOS 自己**请你批准删除,app 无法绕过那个
弹窗。批准后的照片进入**「最近删除」**,iOS 在那里保留 30 天。

### 儿童

app 没有用户生成内容、没有社交功能、没有网络访问、没有广告。分级为 4+。

### 变更

如果本政策有变更,更新后的版本会出现在这个 URL,上面的日期会随之改变。由于 app
不收集任何数据,任何变更都不可能追溯影响从未被收集的数据。

### 联系

问题或反馈:https://github.com/chuanbei2026/album-compact/issues
