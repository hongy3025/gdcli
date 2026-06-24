## 内置 Ping 路由处理器
##
## 提供健康检查端点，用于验证 API 服务是否正常运行。
## 返回服务状态、API 版本和编辑器版本信息。
## 通常作为连接测试和监控的端点使用。

@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

## 处理 ping 请求
##
## 返回服务状态信息，包括 API 版本和 Godot 编辑器版本。
## @param _req 请求对象（未使用）
## @param res 响应对象
func handle(_req: GdApiRequest, res: GdApiResponse) -> void:
    res.json({
        "ok": true,
        "gdapi_version": "0.2.0",
        "editor_version": Engine.get_version_info().get("string", ""),
    })
