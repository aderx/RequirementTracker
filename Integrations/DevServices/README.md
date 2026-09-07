# dev-services

覆盖当前用户所有本地项目的开发服务与脚本。工具由需求记录 App 打包，在「设置 → 脚本配置 → 全局命令 → dev-services」注册、修复或卸载；运行时不依赖 zs-start 或 ZStack 项目配置。

```sh
dev-services                       # 查看服务、内存和端口，选择服务后确认停止
dev-services --list                # 只读服务列表
dev-services --json                # 只读 JSON
dev-services clean                 # 筛选疑似残留，再选择清理
dev-services clean --list          # 只读疑似残留列表
dev-services clean --json          # 只读疑似残留 JSON
dev-services stop 12345            # 预览 PID 所属服务及子进程，确认后停止
dev-services stop 12345 --force    # 显式预览并确认强制停止
```

扫描结合当前用户的进程、项目目录、TCP 端口和系统托管状态。编辑器、MCP 工具和桌面应用不纳入清理；系统托管的数据库服务仅展示。RSS 是进程驻留内存合计，包含共享页，不能等同于实际可释放内存。

疑似残留需要同时满足父进程已退出、无终端、组内进程已运行至少五分钟、CPU 占用低且无活动 TCP 连接。该判断不能证明服务已经废弃，因此清理必须先选择并确认具体进程。

清理计划有效期五分钟，执行前核对 PID、启动时间、命令、所属用户和子进程范围。默认只发送 TERM；仍在运行的进程需另行预览并确认强制停止。工具不会清空系统缓存、使用管理员权限杀进程，或按进程名批量终止。

命令配置和短期计划保存在 `~/Library/Application Support/RequirementTracker/DeveloperTools/DevServices`，与 zs-start 分开。注册不会覆盖已有的同名陌生命令；卸载只移除本工具的命令入口，不停止服务、不删除项目。

开发验证时命令可以指向开发 App。安装正式版后，在正式 App 中修复命令，使其指向 `/Applications/需求记录.app/Contents/Resources/DevServices`。发布包只包含两个运行脚本，不包含测试和本文档。
