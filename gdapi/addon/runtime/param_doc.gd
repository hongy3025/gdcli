## 路由单个参数的文档描述
##
## 由 GdApiRouteDoc.param() 构造，一般不直接实例化。
## 用于在 /help 接口序列化为 JSON 返回给客户端。

@tool
class_name GdApiParamDoc
extends RefCounted

## 参数名
var name: String = ""
## 参数类型字符串（"String", "int", "Dictionary", "Array", "bool" 等，开发者自由约定）
var type: String = ""
## 是否必填
var required: bool = false
## 参数描述
var description: String = ""
## 默认值；null 表示无默认值（必填参数也为 null）
var default = null

## 序列化为字典，供 JSON 响应使用
##
## @return 包含 name/type/required/description/default 五个字段的字典
func to_dict() -> Dictionary:
	return {
		"name": name,
		"type": type,
		"required": required,
		"description": description,
		"default": default,
	}
