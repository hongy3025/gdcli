## 项目信息路由处理器
##
## 提供获取当前 Godot 项目基本信息的 API 端点。
## 返回项目名称、主场景、Godot 版本、项目路径和渲染方法等信息。
## 主要用于项目配置查询和环境检测。

@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

## 处理项目信息请求
##
## 从 ProjectSettings 和 Engine 中提取项目相关信息并返回。
## @param _req 请求对象（未使用）
## @param res 响应对象
func handle(_req: GdApiRequest, res: GdApiResponse) -> void:
	var ps := ProjectSettings
	# 返回项目基本信息
	res.json({
		"ok": true,
		"name": ps.get_setting("application/config/name", ""),
		"main_scene": ps.get_setting("application/run/main_scene", ""),
		"godot_version": Engine.get_version_info().get("string", ""),
		"project_path": ProjectSettings.globalize_path("res://"),
		"rendering_method": ps.get_setting("rendering/renderer/rendering_method", ""),
	})

## 返回该路由的帮助文档
func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc.make("获取当前 Godot 项目基本信息")
		.desc("返回项目名称、主场景、Godot 版本、项目路径和渲染方法等信息；用于项目配置查询和环境检测")
		.returns("项目信息", {
			"ok": "bool",
			"name": "String, 项目名称",
			"main_scene": "String, 主场景路径",
			"godot_version": "String, Godot 引擎版本",
			"project_path": "String, 项目全局路径",
			"rendering_method": "String, 渲染方法",
		})
	)
