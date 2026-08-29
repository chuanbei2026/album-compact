# 回复 App Review(Guideline 2.1 – Information Needed)

## 一、录屏怎么录 —— 两个会让录屏白录的坑

### ⚠️ 坑一:必须先把 app 删掉

Apple 要求录到权限弹窗。**已经装过并授权过的机器不会再弹。** 你手机上如果有
之前装的版本,直接录只会看到它跳过弹窗进首页 —— 那正是缺失的那一格画面。

录之前:长按 app → 删除 → 重新安装 build 2。

(只在设置里关掉权限不够干净:那样重进会走「被拒绝」分支,弹的是设置引导,
不是首次授权弹窗。)

### ⚠️ 坑二:用「选择照片…」,不要给完整访问

这一条同时解决三个问题,而且 app 已经支持(`.limited` 在四处代码里都处理了):

| 问题 | 完整访问 | 选择照片 |
|---|---|---|
| 录屏里出现你的私人照片 | 12,930 张全过一遍 | 只有你挑的那几十张 |
| 审核员要等多久 | 12,506 张要算指纹 + Vision,分钟级 | 几十张,几秒 |
| 权限弹窗 | ✅ 拍得到 | ✅ 一样拍得到 |

挑照片时确保覆盖到:

- **两张完全一致的**(同一张存了两份)→ 首页那条蓝色主按钮才有内容
- **一组连拍**(3 张以上)→「同一时刻多张」那一屏
- **几张聊天截图**→ 分类那几行

没有这三类,录出来的还是一个空界面 —— 等于把被拒的理由再演一遍。

### 录制路线

```
启动(全新安装)
  → 相册权限弹窗:选「选择照片…」,挑 30–50 张(含上面三类)
  → 首页:可回收多少、各分类和数字
  → 完全一致的重复:网格,默认已勾选
  → 返回 → 滑动卡组:左滑清 2 张、右滑留 1 张
  → 返回首页 → 待删清单
  → 点执行 → iOS 自己的删除二次确认弹窗(拍到这一格)
```

最后那格很重要:它证明**删除始终由系统把关**,app 绕不过去。

## 二、回复正文(可直接贴)

> Hello,
>
> Thank you for the review. A screen recording of the full flow on a physical
> device is attached.
>
> **About the empty screen you may have seen.** Album Sweeper works on the
> photos already in the library — it finds duplicates, bursts and screenshots
> and helps the user clear them. On a clean test device with an empty photo
> library there is nothing for it to find, so the main screen correctly reports
> that there is nothing to clean up. We should have said this in the review
> notes on the first submission, and we apologise for the omission.
>
> **To reproduce the recording:**
>
> 1. Install the app on a device that has photos in its library. If the library
>    is empty, add at least: two identical copies of one photo, a burst of
>    three or more frames taken seconds apart, and a few screenshots.
> 2. Launch the app. It asks for photo library access on first launch. Both
>    "Allow Full Access" and "Select Photos…" work; with "Select Photos…",
>    please select images that include the three kinds above.
> 3. The main screen lists what was found. Tapping a row opens that group.
> 4. Nothing is deleted until you confirm. Marked photos go to a pending list;
>    executing it calls the system Photos framework, and iOS itself shows its
>    own confirmation before anything is removed. Deleted items go to Recently
>    Deleted for 30 days.
>
> **No account, no server.** There is no sign-in, no backend and no network
> access of any kind. The binary links no networking framework: `otool -L`
> shows only Accelerate, BackgroundTasks, Charts, CoreFoundation, CoreGraphics,
> Foundation, ImageIO, Photos, SwiftUI, UIKit, UserNotifications and Vision.
> All analysis, including Apple Vision inference, runs on the device.
>
> Our privacy policy is at
> https://github.com/chuanbei2026/album-compact/blob/main/PRIVACY.md
>
> Please let us know if anything else would help.
>
> Thank you,
> Xiangyang Shi

## 三、走哪条路

**Reply to App Review + 附视频** —— 不用重新排队,Notes 已经带上了。
只有在需要换包时才 Update Review(build 2 已上传,如果版本还关联在 build 1 上,
先在 ASC 里把版本改成关联 **build 2**)。
