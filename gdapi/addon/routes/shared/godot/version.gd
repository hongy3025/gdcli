## Godot 版本信息路由处理器
##
## 提供获取 Godot 引擎版本详细信息的 API 端点。
## 返回版本号、主版本号、次版本号、补丁版本号、状态和构建信息。
## 主要用于版本兼容性检查和环境信息收集。

@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

## 处理版本信息请求
##
## 从 Engine 中提取详细的版本信息并返回。
## @param _req 请求对象（未使用）
## @param res 响应对象
func handle(_req: GdApiRequest, res: GdApiResponse) -> void:
	var info := Engine.get_version_info()
	# 返回详细的版本信息
	res.json({
		"ok": true,
		"version": info.get("string", ""),
		"major": info.get("major", 0),
		"minor": info.get("minor", 0),
		"patch": info.get("patch", 0),
		"status": info.get("status", ""),
		"build": info.get("build", ""),
	})
