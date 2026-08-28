# App Store Connect 小工具

两个脚本，用 `~/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8` 直接打
App Store Connect API，不需要 Xcode 登录、不需要装 `cryptography`
（ES256 的 JWT 用 `openssl` 签，再把 DER 转成 raw R‖S）。

| 脚本 | 作用 |
|---|---|
| `asc.py` | 只读探查：账号角色、Bundle ID、证书、描述文件、App 记录 |
| `mkprofile.py` | 用现有 `DISTRIBUTION` 证书建 App Store 描述文件并装到本地 |

```bash
python3 Tools/asc/asc.py          # 看现状
python3 Tools/asc/mkprofile.py    # 建描述文件（幂等性：会重复建同名的，先用 asc.py 查）
```

存在的理由：这个账号没有**云托管发布证书**的权限（403 `FORBIDDEN_ERROR`），
所以 `xcodebuild` 的自动签名走不通 —— 哪怕账号角色是 `ACCOUNT_HOLDER` + `ADMIN`。
自己建描述文件 + 手动签名可以完全绕开那条路。细节见 `fastlane/SUBMISSION.md`。

## 凭据从环境变量来

```bash
export ASC_KEY_ID=XXXXXXXXXX          # App Store Connect → 用户和访问 → 集成
export ASC_ISSUER_ID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx   # 同页面顶部
# 私钥默认找 ~/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8
```

这两个标识符**不是密钥** —— Apple 在网页上明文显示、不打码,没有 `.p8` 私钥它们什么也做不了。
放进环境变量不是因为它们敏感,而是因为公开仓库里留着它们零收益:
真正的私钥万一哪天泄露(备份、丢的笔记本、CI 日志),不该顺带把另外两半也奉上。
