## 路由帮助文档对象
##
## 通过 GdApiRouteDoc.make("...").desc("...").param(...).returns(...) 链式构造。
## 由 route handler 的 doc() 方法返回，内置 /help 路由调用 to_dict()/to_summary_dict() 序列化。

@tool
class_name GdApiRouteDoc
extends RefCounted

const ParamDoc := preload("res://addons/gdapi/runtime/param_doc.gd")

## 一句话功能描述（出现在列表和详情视图）
var summary: String = ""
## 多行详细说明（仅出现在详情视图）
var description: String = ""
## 参数列表
var params: Array[ParamDoc] = []
## 返回值整体说明
var returns_desc: String = ""
## 返回值字段说明（flat dict，键为字段名，值为类型+说明字符串）
var returns_fields: Dictionary = {}
## 调用示例（JSON 请求体字符串数组）
var examples: Array[String] = []

## 静态工厂：创建一个带 summary 的 RouteDoc
##
## @param summary_ 一句话功能描述
## @return 新建的 GdApiRouteDoc 实例
static func make(summary_: String) -> GdApiRouteDoc:
	var d := GdApiRouteDoc.new()
	d.summary = summary_
	return d

## 设置详细描述（fluent）
##
## @param text 多行说明
## @return self 以便链式调用
func desc(text: String) -> GdApiRouteDoc:
	description = text
	return self

## 添加一个参数（fluent）
##
## @param name_ 参数名
## @param type_ 类型字符串
## @param required_ 是否必填
## @param description_ 参数说明
## @param default_ 默认值（null 表示无默认值）
## @return self 以便链式调用
func param(name_: String, type_: String, required_: bool, description_: String, default_ = null) -> GdApiRouteDoc:
	var p := ParamDoc.new()
	p.name = name_
	p.type = type_
	p.required = required_
	p.description = description_
	p.default = default_
	params.append(p)
	return self

## 设置返回值描述与字段（fluent）
##
## @param desc_ 返回值整体说明
## @param fields_ 字段字典，键为字段名，值为类型+说明字符串
## @return self 以便链式调用
func returns(desc_: String, fields_: Dictionary = {}) -> GdApiRouteDoc:
	returns_desc = desc_
	returns_fields = fields_
	return self

## 添加一个 JSON 请求示例（fluent）
##
## @param json JSON 字符串形式的请求体示例
## @return self 以便链式调用
func example(json: String) -> GdApiRouteDoc:
	examples.append(json)
	return self

## 完整序列化（详情视图）
##
## @return 含 summary/description/params/returns/examples 的字典
func to_dict() -> Dictionary:
	var param_dicts: Array = []
	for p in params:
		param_dicts.append(p.to_dict())
	return {
		"summary": summary,
		"description": description,
		"params": param_dicts,
		"returns": {
			"description": returns_desc,
			"fields": returns_fields,
		},
		"examples": examples,
	}

## 简要序列化（列表视图）
##
## @return 仅含 summary 与 params:[{name, required}] 的字典
func to_summary_dict() -> Dictionary:
	var param_summary: Array = []
	for p in params:
		param_summary.append({"name": p.name, "required": p.required})
	return {
		"summary": summary,
		"params": param_summary,
	}
