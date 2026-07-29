@tool
extends "res://addons/gdapi/runtime/route_handler.gd"
const S := preload("res://addons/gdapi/runtime/services/uid_repair.gd")
func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	var out := S.repair(req.body)
	if out.ok: res.json(out)
	else: res.error(out.error, out.code, 400, out.get("changes", {}))
func doc() -> GdApiRouteDoc: return GdApiRouteDoc.make("扫描并修复资源 UID").param("roots", "Array[String]", false, "扫描根", ["res://"]).param("dry_run", "bool", false, "只规划不写入", true).param("force", "bool", false, "确认写入", false).returns("UID 计划", {"ok":"bool", "scanned":"int", "missing":"int", "collisions":"int", "changes":"Array", "changed":"bool", "undoable":"bool"}).example("{\"roots\":[\"res://fixtures\"],\"dry_run\":true}")

