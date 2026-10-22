# OCAgent

OCAgent 是一个运行在 [OpenComputers](https://github.com/GTNewHorizons/OpenComputers) / OpenOS 上的 Lua AI 编程代理。它可以通过自然语言与 AI 交流，并使用文件读写、文件搜索、Shell 命令、Lua 执行等工具协助完成开发任务。

## 功能

- 支持基于会话的连续对话和会话恢复
- 读取、写入和编辑 OpenOS 文件
- 搜索文件和文本内容
- 执行 OpenOS Shell 命令及 Lua 代码
- 启动时检查新版本，并支持在线更新

## 环境要求

- OpenComputers 计算机，至少2x T3.5内存，至少 T2硬盘
- 可用的因特网卡卡（Internet Card）
- 可用的 DeepSeek API Key

## 安装

在 OpenOS 的 Shell 中运行：

```sh
wget -f https://github.xutongxin.me/https://raw.githubusercontent.com/hxync/OCAgent/main/installer.lua /tmp/installer.lua && /tmp/installer.lua
```

安装程序会：

1. 将程序安装到 `/usr/apps/agent/`
2. 创建 `/home/ai.lua` 启动入口

安装完成后，可以运行：

```sh
ai
```

## 配置 API Key

程序启动时会优先读取：

```text
/etc/api_key
```

如果该文件不存在或内容为空，程序要求会通过剪贴板输入 API Key

- 通过剪切板输入的 API key 不会显示，不会保存。

你可以使用下面的命令将 API key 保存到此 OpenComputers 计算机上

```sh
echo "你的 DeepSeek API Key" > /etc/api_key
```

API Key 只会在运行时用于请求 DeepSeek API。更换密钥时，直接更新 `/etc/api_key` 即可。

**不要在不信任的服务器上保存 API key**

## 使用方式

首次启动时，程序会显示会话选择菜单。可以创建新会话，也可以选择已有会话继续工作。

会话记录保存在安装目录下的：

```text
/usr/apps/agent/sessions/
```

## 项目结构

```text
.
├── agent/
│   ├── ai.lua              # DeepSeek API 请求和流式响应处理
│   ├── init.lua            # 程序入口、会话选择和工具注册
│   ├── Session.lua         # 会话管理
│   ├── selecter.lua        # 交互式选择菜单
│   ├── lib/                # 通用库
│   ├── prompts/            # 系统提示词
│   └── tools/              # 文件、Shell、Lua 和重启等工具
├── installer.lua           # OpenOS 安装和更新脚本
└── VERSION                 # 当前版本
```

## 安全注意事项

- 不要在不可信的服务器中保存 API Key。
- 执行安装脚本前，请检查脚本内容和下载地址。
- 不要盲目执行 AI 生成的命令，尤其是删除、覆盖或联网操作。
- 会话记录可能包含代码、路径和用户输入，公开存档前请检查 `sessions/` 内容。
- 使用在线更新前，请确认仓库地址和分支可信。

## 网络和服务

默认 API 地址为：

```text
https://api.deepseek.com
```

默认模型配置位于 `agent/ai.lua`。程序还会自动从 GitHub 仓库检查更新。
