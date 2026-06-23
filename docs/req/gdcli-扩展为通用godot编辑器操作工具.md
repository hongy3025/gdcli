## 将 gdcli 扩展为通用godot编辑器操作工具

现有 gdcli 只是连接 godot editor 的 LSP server，作为 lsp 的查询客户端。
现在需要将这个工具扩展为通用 godot 编辑器的通用操作工具。

## gdcli 新功能

- gdcli 可以连接某个正在运行中的实例的 godot 编辑器，可以向它发送各种命令和数据，来操控 godot 编辑器。必须使用 --project 来指定项目工程目录。
- 发送命令和数据的方式，模拟 curl 的形态，例如这样： gdcli --project <project_dir> exec <command>  --data "（可选）json格式的的数据"。返回结果，通过 stdout 返回； 错误信息通过 stderr 返回。
  > --project <project_dir> 参数可以可选。当可选时，隐藏从当前目录获取 godot 工程信息。
  > 要实现的命令（功能），完整实现项目 D:\AI\godot-ws\godot-mcp 中的功能。
  > gdcli 需要和 godot 编辑器中的插件（扩展）gdapi 通讯。（下一节描述）
- 现有的所有子命令功能保持不变，降级到 gdcli lsp，继续使用。

## gdapi 扩展

为了确保 gdcli 能和 godot editor 通讯。需要用 rust 实现一个 GDExtension， 在 godot 编辑器启动时，在编辑器进程内部启动一个 restful 形态的 http api server，监听到特定的端口。

rust实现GDExtension的方法，参考： D:\AI\godot-ws\godot-tetro

gdapi 启动服务监听的端口从 7890 开始，逐个尝试监听可用性，若不可用则端口号数字+1；若可用则监听；监听后，保存一个包含监听端口号的文件，到 .godot/ 目录下，这样 gdcli 可以读取到。

注意： gdcli 现有的 lsp 功能，也需要连接 godot 编辑器的 lsp server 端口。在多个 godot 实例同时启动时，应该会让 lsp server 监听到不同的端口（这个需要进一步确认是否如此），所以需要设计一种方式，让 gdcli 获取到特定 godot 实例的 lsp server 端口。

gdapi 的扩展的 rust 部分，要设计为极薄、极简形态，只负责处理 http 监听，http 协议编解码。然后路由到 gdscript 编写的脚本。json的编解码，如果 gdscript 有这个能力，就尽量用 gdscript 脚本。

gdapi 的所有命令的真正实现，都实现在 gdscript 脚本中。设计一种类似于 next.js, nuxt.js 这样的基于文件系统的路由机制，将命令路由到特定的 gdscript 处理脚本文件中。要精心设计机制，以便让这些 gdscript 脚本清晰的区分 editor only 脚本 或 play only 脚本。