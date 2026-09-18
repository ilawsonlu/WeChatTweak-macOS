# WeChatTweak

[![README](https://img.shields.io/badge/GitHub-black?logo=github&logoColor=white)](https://github.com/sunnyyoung/WeChatTweak)
[![README](https://img.shields.io/badge/Telegram-black?logo=telegram&logoColor=white)](https://t.me/wechattweak)
[![README](https://img.shields.io/badge/FAQ-black?logo=googledocs&logoColor=white)](https://github.com/sunnyyoung/WeChatTweak/wiki/FAQ)

A command-line tool for tweaking WeChat.

## 功能

- 阻止消息撤回
- 阻止自动更新
- 客户端多开

## 微信 4.1.15.18 支持

当前配置支持官网版微信 4.1.15.18（`CFBundleVersion` `270098`）的 Apple Silicon 切片：

- 阻止消息撤回
- 阻止微信自动更新覆盖补丁

新版微信已将相关逻辑迁移到 `Contents/Resources/wechat.dylib`。补丁会先校验原始字节，
不匹配时拒绝写入，并在首次修改前保存 `wechat.dylib.270098.bak`。历史版本的原地多开
补丁没有直接沿用到该构建；本条目不宣称支持 4.1.15.18 多开。

## 安装&使用

### 微信 4.1.15.18 一键安装（Apple Silicon）

先完全退出微信，然后在终端执行：

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/ilawsonlu/WeChatTweak-macOS/master/install.sh)"
```

脚本会检查 macOS、Apple Silicon、微信构建号和 Xcode Command Line Tools，随后从本仓库
构建工具、应用补丁、保留原始 `wechat.dylib.270098.bak`、严格校验签名并重新启动微信。
版本或原始字节不匹配时会拒绝修改。查看所有选项：

```bash
./install.sh --help
```

如果希望先检查而不修改微信：

```bash
./install.sh --dry-run
```

### Homebrew（上游版本）

```bash
# 安装
brew install sunnyyoung/tap/wechattweak

# 更新
brew upgrade wechattweak

# 执行 Patch
wechattweak patch

# 查看所有支持的 WeChat 版本
wechattweak versions
```

从本仓库构建并使用刚更新的本地配置：

```bash
swift build -c release
.build/release/wechattweak patch --config "$PWD/config.json"
```

执行前请完全退出微信。补丁与签名流程尚不能替代双账号真实撤回测试；安装后请重新打开微信，
用另一个账号发送并撤回一条测试消息确认效果。

## 参考

- [微信 macOS 客户端无限多开功能实践](https://blog.sunnyyoung.net/wei-xin-macos-ke-hu-duan-wu-xian-duo-kai-gong-neng-shi-jian/)
- [微信 macOS 客户端拦截撤回功能实践](https://blog.sunnyyoung.net/wei-xin-macos-ke-hu-duan-lan-jie-che-hui-gong-neng-shi-jian/)
- [让微信 macOS 客户端支持 Alfred](https://blog.sunnyyoung.net/rang-wei-xin-macos-ke-hu-duan-zhi-chi-alfred/)

## 贡献者

This project exists thanks to all the people who contribute.

[![Contributors](https://contrib.rocks/image?repo=sunnyyoung/WeChatTweak)](https://github.com/sunnyyoung/WeChatTweak/graphs/contributors)

## License

The [AGPL-3.0](LICENSE).
