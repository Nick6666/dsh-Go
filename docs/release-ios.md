# iOS 安装包（未签名 IPA）

Android 版走 GitHub Releases 的 APK 和 App 内更新；iOS 没有这条链路：App Store 之外只能靠
侧载，而侧载的包必须由**安装的人自己签名**。所以这里发布的是**未签名 IPA**，发布者不需要
Apple 开发者账号，也不需要在一台真机上验证安装。

## 产物

| 项 | 约定 | 例子 |
|---|---|---|
| 文件名 | `dsh-go-<版本名>-ios-arm64.ipa`；没嵌入引擎时加 `-remote` | `dsh-go-1.1.0-ios-arm64.ipa` |
| 版本名 | `app/pubspec.yaml` 的 `version:` 去掉 `+N`，即 `CFBundleShortVersionString` | `1.1.0` |
| 构建号 | `CFBundleVersion`，构建分钟（`tooling/build_number.py`，UTC+8），和 APK 同一条序列 | `11162328` |
| 校验和 | `SHA256SUMS`，`shasum -a 256` 的标准输出 | `<hex>  dsh-go-1.1.0-ios-arm64.ipa` |
| tag | `ios-v` + 版本名 | `ios-v1.1.0` |

iOS 不走 `update.json`、不做 App 内更新，也不产生增量补丁：改一次都要重签，增量没有意义。

## 构建

依赖：macOS + Xcode（CI 用 26.6，本机 27.2 也能编）、Flutter 3.47.7、rustup（
`tooling/ios/build-phone-self-runner.sh` 用固定工具链）、python3.10 以上（`python3` 指向旧版本时
设 `PYTHON=`）。

```sh
tooling/ios/prepare-engine.sh      # 可选；不跑就得到 -remote 包
tooling/ios/build-ipa.sh           # 产物在 dist-ios/
tooling/ios/build-ipa.sh --dry-run # 只打印命令
```

`prepare-engine.sh` 只准备 NodeMobile 与运行时 ZIP；Xcode 阶段还要编原生 addon 和 iSH guest，
后者需要 `clang`、`ld.lld`、`meson`、`ninja`（`brew install llvm lld meson ninja`）。缺这些工具时
构建会在 guest 那一步失败，而不会悄悄给一个没有引擎的包：`build-ipa.sh` 检查产出的 `.app`，
`app/ios/Engine/.ready` 存在却没有 `Frameworks/NodeMobile.framework` 和 `dsh-runtime/runtime.zip`
时直接报错。确实要只连远程主机的包，就把 `app/ios/Engine` 挪开，或用 `--remote-only`。

`build-ipa.sh` 不签名、不导出：`flutter build ios --release --no-codesign` 之后只做打包、核对
`CFBundleShortVersionString`/`CFBundleVersion`、算 SHA-256。

## 安装

未签名 IPA 只有重签之后才能装。三条路，按有没有 Mac 选：

1. **Xcode（有 Mac）**：`app/ios/README.md` 的流程，在 Xcode 里给 `Runner` 和 `ShareExtension`
   两个 target 选 Team，然后 `flutter run --release -d <设备>`。Personal Team 每次签名 7 天、
   最多 3 台设备、没有推送。
2. **AltStore / Sideloadly（无 Mac）**：把 IPA 交给工具，用同一个 Apple ID 重签并安装；
   同样受 7 天和 3 台设备限制，需要先信任描述文件。
3. **自己的企业/开发者证书**：`codesign --force --deep` 重签 `Payload/Runner.app` 及其中
   `Frameworks/*.framework`、`PlugIns/*.appex`，再 `zip` 回 IPA。嵌套的 framework 必须逐个签，
   顺序错了会在启动时被系统拒掉。

Bundle ID 是 `io.github.ccch1mneyyy.dshgo`。重签时不想和别人的包冲突，就一起改三处：两个
target 的 `PRODUCT_BUNDLE_IDENTIFIER`、两份 `.entitlements` 里的 App Group、
`ShareExtension/ShareInbox.swift` 的 `group`。扩展 ID 必须以主应用 ID 开头。

## 限制

- 没有推送、没有 App 内更新、没有 APK 那种自安装。
- 本机引擎、手机操控、画中画、语音这些能力的准入与真机行为，编过不等于验过；真机结论以
  `app/ios/README.md` 记录的复验为准。

## CI

`.github/workflows/ios-ipa.yml`：`workflow_dispatch` 手工跑，推送 `ios-v*` tag 时另外把 IPA 挂到
同名 Release。构建在 `macos-26` 上装 Flutter 3.47.7 与 iSH 工具链，跑 `prepare-engine.sh` 和
`build-ipa.sh`，产物作为 workflow artifact 保留；不需要任何 secret。
