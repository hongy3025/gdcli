## 域服务统一的用户节点路径解析器。
##
## 契约（M4 起）：域服务既接受路由文档里的场景根相对路径（如 `"AnimationTree"`、
## `"Button"`、`"A/B"`、裸场景根名），也接受 `node/*` 响应回传的绝对用户路径
## `/root/<当前编辑场景根名>/A/B`；两者解析到同一个真实节点，并统一回传规范化
## 的绝对用户路径。通用 `node/*` 路由保持不变，仍只接受绝对 `/root/...`
## （见 GdApiNodeEditor.find）。
##
## 为什么不能直接 `root.get_node_or_null(NodePath("/root/<name>/..."))`：编辑器里
## 编辑场景根的真实树路径是 `/root/@EditorNode@...`（见 audio_editor._user_path 的
## 说明），绝对 NodePath 会从 SceneTree 根解析而找不到编辑场景内的节点。因此这里
## 先去掉 `/root/<场景根名>/` 前缀，再从编辑场景根做相对查找。

@tool
class_name GdApiNodePathResolver
extends RefCounted

const ErrorCodes := preload("res://addons/gdapi/runtime/error_codes.gd")


## 解析用户路径，返回 {ok:true, node:Node, path:String} 或 {ok:false, code, error}。
## path 始终是规范化的绝对用户路径 `/root/<场景根名>[/...]`。
static func resolve(path: Variant) -> Dictionary:
	if typeof(path) != TYPE_STRING:
		return {
			"ok": false, "code": ErrorCodes.INVALID_PARAM, "error": "node path must be a string"
		}
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return {"ok": false, "code": ErrorCodes.NOT_FOUND, "error": "no scene is currently open"}
	var root_name := String(root.name)
	var raw := String(path).strip_edges()
	var relative := raw.trim_prefix("/")
	if relative.begins_with("root/"):
		relative = relative.substr("root/".length())
	var parts := relative.split("/", false)
	# 绝对与相对输入都接受，并容忍多带一次场景根名。
	if parts.size() > 0 and parts[0] == root_name:
		parts = parts.slice(1)
	relative = "/".join(parts)
	if ".." in parts or ":" in relative:
		return {
			"ok": false,
			"code": ErrorCodes.PERMISSION_DENIED,
			"error": "node paths must remain inside the edited scene",
		}
	var node: Node = root if relative == "" else root.get_node_or_null(NodePath(relative))
	if node == null:
		return {
			"ok": false,
			"code": ErrorCodes.NOT_FOUND,
			"error": "node not found: " + raw,
		}
	var prefix := "/root/" + root_name
	return {
		"ok": true,
		"node": node,
		"path": prefix if relative == "" else prefix + "/" + relative,
	}
