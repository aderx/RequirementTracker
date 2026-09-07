# zs-start

由需求记录 App 打包维护。在「设置 → 脚本配置 → 全局命令 → zs-start」中查看命令状态、注册、修复或卸载。项目切换与启动在终端中操作；App 的「项目脚本」用于配置已有的自定义快捷脚本。

```sh
zs-start project                       # 选择默认 ZStack 仓库
zs-start project zstack-ui-next-dev     # 按 workspace 下的名称切换
zs-start project --current             # 查看默认仓库
zs-start fe                            # 原有前端启动流程
zs-start cloud:bff                     # 原有 Cloud BFF 启动流程
zs-start zns:bff                       # 原有 ZNS BFF 启动流程
```

注册命令无需先选择项目；首次使用可运行 `zs-start project`。项目选择保存在 `~/Library/Application Support/RequirementTracker/DeveloperTools/zs-start.json`。切换的是后续启动的默认仓库，终端当前工作目录保持原状；原有 worktree 和终端记忆继续生效。

所有本地项目的服务与内存管理使用独立的 [dev-services](../DevServices/README.md) 命令。

开发验证时命令可以指向开发 App。安装正式版后，在正式 App 中修复命令，使其指向 `/Applications/需求记录.app` 中的工具资源。发布打包只包含运行脚本，不包含测试和本文档。
