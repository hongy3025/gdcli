# 阶段 4：路由批量迁移（godot-mcp 12 个命令） 实现计划

> **面向 AI 代理的工作者：** 必需子技能：使用 superpowers:subagent-driven-development（推荐）或 superpowers:executing-plans 逐任务实现此计划。步骤使用复选框（`- [ ]`）语法来跟踪进度。

**目标：** 将 godot-mcp 的 12 个命令迁移为 gdapi 的 GDScript 路由处理脚本，让 `gdcli exec` 能调用它们。

**架构：** 每个路由是一个独立的 GDScript 文件，继承 `GdApiRouteHandler` 基类，实现 `handle(params: Dictionary) -> Dictionary` 方法。路由文件放在 `gdapi/addon/routes/editor/` 或 `gdapi/addon/routes/shared/` 目录下，由 router.gd 自动扫描注册。

**技术栈：** GDScript（Godot 4.3+）/ EditorInterface API / ResourceSaver / PackedScene

---

## 文件结构

**新建：**
- `gdapi/addon/routes/shared/godot/version.gd` — GET godot version
- `gdapi/addon/routes/shared/project/info.gd` — GET project info
- `gdapi/addon/routes/editor/project/run.gd` — run project
- `gdapi/addon/routes/editor/project/stop.gd` — stop project
- `gdapi/addon/routes/editor/project/debug_output.gd` — debug output (placeholder)
- `gdapi/addon/routes/editor/scene/create.gd` — create scene
- `gdapi/addon/routes/editor/scene/add_node.gd` — add node to scene
- `gdapi/addon/routes/editor/scene/load_sprite.gd` — load sprite texture
- `gdapi/addon/routes/editor/scene/save.gd` — save scene
- `gdapi/addon/routes/editor/scene/export_mesh_library.gd` — export mesh library
- `gdapi/addon/routes/shared/uid/get.gd` — get UID for file
- `gdapi/addon/routes/editor/uid/update_all.gd` — update all UIDs

**修改：**
- `gdapi/addon/runtime/builtin_routes.gd` — 无需修改（router.gd 已自动扫描）
- `gdapi/addon/` — 需要重新嵌入到 gdcli 二进制（Phase 2 的 include_dir!）

---

## 任务 1：共享查询路由（godot/version + project/info + uid/get）

**文件：**
- 创建：`gdapi/addon/routes/shared/godot/version.gd`
- 创建：`gdapi/addon/routes/shared/project/info.gd`
- 创建：`gdapi/addon/routes/shared/uid/get.gd`

- [ ] **步骤 1：创建 godot/version.gd**

```gdscript
@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

func handle(_params: Dictionary) -> Dictionary:
    var info := Engine.get_version_info()
    return {
        "ok": true,
        "version": info.get("string", ""),
        "major": info.get("major", 0),
        "minor": info.get("minor", 0),
        "patch": info.get("patch", 0),
        "status": info.get("status", ""),
        "build": info.get("build", ""),
    }
```

- [ ] **步骤 2：创建 project/info.gd**

```gdscript
@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

func handle(_params: Dictionary) -> Dictionary:
    var ps := ProjectSettings
    return {
        "ok": true,
        "name": ps.get_setting("application/config/name", ""),
        "main_scene": ps.get_setting("application/run/main_scene", ""),
        "godot_version": Engine.get_version_info().get("string", ""),
        "project_path": ProjectSettings.globalize_path("res://"),
        "rendering_method": ps.get_setting("rendering/renderer/rendering_method", ""),
    }
```

- [ ] **步骤 3：创建 uid/get.gd**

```gdscript
@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

func handle(params: Dictionary) -> Dictionary:
    var file_path: String = params.get("file_path", "")
    if file_path.is_empty():
        return {"error": "file_path is required", "code": "missing_param"}

    # 确保路径以 res:// 开头
    if not file_path.begins_with("res://"):
        file_path = "res://" + file_path

    var abs_path := ProjectSettings.globalize_path(file_path)
    if not FileAccess.file_exists(abs_path):
        return {"error": "file not found: " + file_path, "code": "not_found"}

    var uid_path := file_path + ".uid"
    var uid_content := ""
    var uid_exists := false

    if FileAccess.file_exists(uid_path):
        var f := FileAccess.open(uid_path, FileAccess.READ)
        if f:
            uid_content = f.get_as_text().strip_edges()
            f.close()
            uid_exists = true

    return {
        "ok": true,
        "file": file_path,
        "absolute_path": abs_path,
        "uid": uid_content,
        "uid_exists": uid_exists,
    }
```

- [ ] **步骤 4：Commit**

```bash
git add -A
git commit -m "feat(gdapi): add shared query routes (godot/version, project/info, uid/get)"
```

---

## 任务 2：编辑器项目控制路由（project/run + project/stop + project/debug_output）

**文件：**
- 创建：`gdapi/addon/routes/editor/project/run.gd`
- 创建：`gdapi/addon/routes/editor/project/stop.gd`
- 创建：`gdapi/addon/routes/editor/project/debug_output.gd`

- [ ] **步骤 1：创建 project/run.gd**

```gdscript
@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

func handle(params: Dictionary) -> Dictionary:
    var scene_path: String = params.get("scene_path", "")

    if scene_path.is_empty():
        # 运行主场景
        EditorInterface.play_main_scene()
        return {"ok": true, "action": "play_main_scene"}

    # 运行指定场景
    # 确保路径以 res:// 开头
    if not scene_path.begins_with("res://"):
        scene_path = "res://" + scene_path

    # 验证场景文件存在
    var abs_path := ProjectSettings.globalize_path(scene_path)
    if not FileAccess.file_exists(abs_path):
        return {"error": "scene not found: " + scene_path, "code": "not_found"}

    EditorInterface.play_custom_scene(scene_path)
    return {"ok": true, "action": "play_custom_scene", "scene": scene_path}
```

- [ ] **步骤 2：创建 project/stop.gd**

```gdscript
@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

func handle(_params: Dictionary) -> Dictionary:
    if not EditorInterface.is_playing_scene():
        return {"ok": true, "action": "stop", "message": "not playing"}

    EditorInterface.stop_playing_scene()
    return {"ok": true, "action": "stop"}
```

- [ ] **步骤 3：创建 project/debug_output.gd**

```gdscript
@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

# MVP: debug_output 需要运行时缓冲区支持，当前返回占位响应。
# 后续迭代将实现环形缓冲区订阅 EditorInterface 日志信号。

func handle(params: Dictionary) -> Dictionary:
    var _since: int = params.get("since", 0)
    var _limit: int = params.get("limit", 100)

    # TODO: 实现滚动缓冲区
    # 当前返回 not implemented 占位
    return {
        "ok": false,
        "error": "debug_output not implemented in this version",
        "code": "not_implemented",
        "hint": "This feature requires runtime buffer support. Will be implemented in a future version.",
    }
```

- [ ] **步骤 4：Commit**

```bash
git add -A
git commit -m "feat(gdapi): add editor project routes (run, stop, debug_output placeholder)"
```

---

## 任务 3：场景操作路由（scene/create + scene/add_node + scene/load_sprite + scene/save + scene/export_mesh_library）

**文件：**
- 创建：`gdapi/addon/routes/editor/scene/create.gd`
- 创建：`gdapi/addon/routes/editor/scene/add_node.gd`
- 创建：`gdapi/addon/routes/editor/scene/load_sprite.gd`
- 创建：`gdapi/addon/routes/editor/scene/save.gd`
- 创建：`gdapi/addon/routes/editor/scene/export_mesh_library.gd`

- [ ] **步骤 1：创建 scene/create.gd**

```gdscript
@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

func handle(params: Dictionary) -> Dictionary:
    var scene_path: String = params.get("scene_path", "")
    if scene_path.is_empty():
        return {"error": "scene_path is required", "code": "missing_param"}

    var root_type: String = params.get("root_node_type", "Node2D")

    # 确保路径以 res:// 开头
    if not scene_path.begins_with("res://"):
        scene_path = "res://" + scene_path

    # 创建根节点
    var root_node: Node = null
    if ClassDB.class_exists(root_type) and ClassDB.can_instantiate(root_type):
        root_node = ClassDB.instantiate(root_type)
    else:
        return {"error": "cannot instantiate node type: " + root_type, "code": "invalid_type"}

    root_node.name = "root"
    root_node.owner = root_node

    # 确保目录存在
    var dir_path := scene_path.get_base_dir()
    if dir_path != "res://":
        var abs_dir := ProjectSettings.globalize_path(dir_path)
        if not DirAccess.dir_exists_absolute(abs_dir):
            DirAccess.make_dir_recursive_absolute(abs_dir)

    # 打包并保存场景
    var packed := PackedScene.new()
    var pack_result := packed.pack(root_node)
    if pack_result != OK:
        return {"error": "failed to pack scene: " + str(pack_result), "code": "pack_failed"}

    var save_result := ResourceSaver.save(packed, scene_path)
    if save_result != OK:
        return {"error": "failed to save scene: " + str(save_result), "code": "save_failed"}

    # 在编辑器中刷新
    EditorInterface.reload_scene_from_path(scene_path)

    return {
        "ok": true,
        "path": scene_path,
        "root_type": root_type,
    }
```

- [ ] **步骤 2：创建 scene/add_node.gd**

```gdscript
@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

func handle(params: Dictionary) -> Dictionary:
    var scene_path: String = params.get("scene_path", "")
    var node_type: String = params.get("node_type", "")
    var node_name: String = params.get("node_name", "")
    var parent_path: String = params.get("parent_node_path", "root")
    var properties: Dictionary = params.get("properties", {})

    if scene_path.is_empty():
        return {"error": "scene_path is required", "code": "missing_param"}
    if node_type.is_empty():
        return {"error": "node_type is required", "code": "missing_param"}
    if node_name.is_empty():
        return {"error": "node_name is required", "code": "missing_param"}

    if not scene_path.begins_with("res://"):
        scene_path = "res://" + scene_path

    # 加载场景
    var scene := load(scene_path)
    if not scene:
        return {"error": "failed to load scene: " + scene_path, "code": "load_failed"}

    var scene_root := scene.instantiate()

    # 找到父节点
    var parent: Node = scene_root
    if parent_path != "root":
        var relative_path := parent_path.replace("root/", "")
        parent = scene_root.get_node(relative_path)
        if not parent:
            return {"error": "parent node not found: " + parent_path, "code": "parent_not_found"}

    # 创建新节点
    var new_node: Node = null
    if ClassDB.class_exists(node_type) and ClassDB.can_instantiate(node_type):
        new_node = ClassDB.instantiate(node_type)
    else:
        return {"error": "cannot instantiate node type: " + node_type, "code": "invalid_type"}

    new_node.name = node_name

    # 设置属性
    for prop in properties:
        var value = properties[prop]
        # 如果值是 res:// 路径，加载为资源
        if typeof(value) == TYPE_STRING and value.begins_with("res://"):
            value = load(value)
        new_node.set(prop, value)

    # 添加到父节点
    parent.add_child(new_node)
    new_node.owner = scene_root

    # 保存场景
    var packed := PackedScene.new()
    var pack_result := packed.pack(scene_root)
    if pack_result != OK:
        return {"error": "failed to pack scene: " + str(pack_result), "code": "pack_failed"}

    var abs_path := ProjectSettings.globalize_path(scene_path)
    var save_result := ResourceSaver.save(packed, abs_path)
    if save_result != OK:
        return {"error": "failed to save scene: " + str(save_result), "code": "save_failed"}

    return {
        "ok": true,
        "node_name": node_name,
        "node_type": node_type,
        "parent": parent_path,
    }
```

- [ ] **步骤 3：创建 scene/load_sprite.gd**

```gdscript
@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

func handle(params: Dictionary) -> Dictionary:
    var scene_path: String = params.get("scene_path", "")
    var node_path: String = params.get("node_path", "")
    var texture_path: String = params.get("texture_path", "")

    if scene_path.is_empty():
        return {"error": "scene_path is required", "code": "missing_param"}
    if node_path.is_empty():
        return {"error": "node_path is required", "code": "missing_param"}
    if texture_path.is_empty():
        return {"error": "texture_path is required", "code": "missing_param"}

    if not scene_path.begins_with("res://"):
        scene_path = "res://" + scene_path
    if not texture_path.begins_with("res://"):
        texture_path = "res://" + texture_path

    # 加载场景
    var scene := load(scene_path)
    if not scene:
        return {"error": "failed to load scene: " + scene_path, "code": "load_failed"}

    var scene_root := scene.instantiate()

    # 找到精灵节点
    var sprite_path := node_path.replace("root/", "")
    var sprite_node = scene_root.get_node(sprite_path)
    if not sprite_node:
        return {"error": "node not found: " + node_path, "code": "node_not_found"}

    # 验证类型
    if not (sprite_node is Sprite2D or sprite_node is Sprite3D or sprite_node is TextureRect):
        return {"error": "node is not a sprite type: " + sprite_node.get_class(), "code": "invalid_type"}

    # 加载纹理
    var texture = load(texture_path)
    if not texture:
        return {"error": "failed to load texture: " + texture_path, "code": "texture_not_found"}

    # 设置纹理
    sprite_node.texture = texture

    # 保存场景
    var packed := PackedScene.new()
    var pack_result := packed.pack(scene_root)
    if pack_result != OK:
        return {"error": "failed to pack scene: " + str(pack_result), "code": "pack_failed"}

    var abs_path := ProjectSettings.globalize_path(scene_path)
    var save_result := ResourceSaver.save(packed, abs_path)
    if save_result != OK:
        return {"error": "failed to save scene: " + str(save_result), "code": "save_failed"}

    return {
        "ok": true,
        "node": node_path,
        "texture": texture_path,
    }
```

- [ ] **步骤 4：创建 scene/save.gd**

```gdscript
@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

func handle(params: Dictionary) -> Dictionary:
    var scene_path: String = params.get("scene_path", "")
    var new_path: String = params.get("new_path", "")

    if scene_path.is_empty():
        return {"error": "scene_path is required", "code": "missing_param"}

    if not scene_path.begins_with("res://"):
        scene_path = "res://" + scene_path

    # 验证场景文件存在
    var abs_path := ProjectSettings.globalize_path(scene_path)
    if not FileAccess.file_exists(abs_path):
        return {"error": "scene not found: " + scene_path, "code": "not_found"}

    # 如果指定了新路径，确保目录存在
    var save_path := scene_path
    if not new_path.is_empty():
        if not new_path.begins_with("res://"):
            new_path = "res://" + new_path
        save_path = new_path
        var new_dir := save_path.get_base_dir()
        if new_dir != "res://":
            var abs_dir := ProjectSettings.globalize_path(new_dir)
            if not DirAccess.dir_exists_absolute(abs_dir):
                DirAccess.make_dir_recursive_absolute(abs_dir)

    # 加载并保存场景
    var scene := load(scene_path)
    if not scene:
        return {"error": "failed to load scene: " + scene_path, "code": "load_failed"}

    var save_result := ResourceSaver.save(scene, save_path)
    if save_result != OK:
        return {"error": "failed to save scene: " + str(save_result), "code": "save_failed"}

    return {
        "ok": true,
        "path": save_path,
    }
```

- [ ] **步骤 5：创建 scene/export_mesh_library.gd**

```gdscript
@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

func handle(params: Dictionary) -> Dictionary:
    var scene_path: String = params.get("scene_path", "")
    var output_path: String = params.get("output_path", "")
    var mesh_item_names: Array = params.get("mesh_item_names", [])

    if scene_path.is_empty():
        return {"error": "scene_path is required", "code": "missing_param"}
    if output_path.is_empty():
        return {"error": "output_path is required", "code": "missing_param"}

    if not scene_path.begins_with("res://"):
        scene_path = "res://" + scene_path
    if not output_path.begins_with("res://"):
        output_path = "res://" + output_path

    # 加载场景
    var scene := load(scene_path)
    if not scene:
        return {"error": "failed to load scene: " + scene_path, "code": "load_failed"}

    var scene_root := scene.instantiate()

    # 创建 MeshLibrary
    var mesh_library := MeshLibrary.new()
    var item_id := 0
    var use_specific := mesh_item_names.size() > 0

    for child in scene_root.get_children():
        if use_specific and not (child.name in mesh_item_names):
            continue

        var mesh_instance: MeshInstance3D = null
        if child is MeshInstance3D:
            mesh_instance = child
        else:
            # 在子节点中查找
            for descendant in child.get_children():
                if descendant is MeshInstance3D:
                    mesh_instance = descendant
                    break

        if mesh_instance and mesh_instance.mesh:
            mesh_library.create_item(item_id)
            mesh_library.set_item_name(item_id, child.name)
            mesh_library.set_item_mesh(item_id, mesh_instance.mesh)

            # 添加碰撞形状
            for collision_child in child.get_children():
                if collision_child is CollisionShape3D and collision_child.shape:
                    mesh_library.set_item_shapes(item_id, [collision_child.shape])
                    break

            item_id += 1

    if item_id == 0:
        return {"error": "no valid meshes found in scene", "code": "no_meshes"}

    # 确保输出目录存在
    var out_dir := output_path.get_base_dir()
    if out_dir != "res://":
        var abs_dir := ProjectSettings.globalize_path(out_dir)
        if not DirAccess.dir_exists_absolute(abs_dir):
            DirAccess.make_dir_recursive_absolute(abs_dir)

    # 保存 MeshLibrary
    var save_result := ResourceSaver.save(mesh_library, output_path)
    if save_result != OK:
        return {"error": "failed to save MeshLibrary: " + str(save_result), "code": "save_failed"}

    return {
        "ok": true,
        "output": output_path,
        "item_count": item_id,
    }
```

- [ ] **步骤 6：Commit**

```bash
git add -A
git commit -m "feat(gdapi): add scene operation routes (create, add_node, load_sprite, save, export_mesh_library)"
```

---

## 任务 4：UID 操作路由（uid/update_all）+ 重新嵌入 addon

**文件：**
- 创建：`gdapi/addon/routes/editor/uid/update_all.gd`
- 重新嵌入 addon 到 gdcli 二进制（运行 `cargo build -p gdcli`）

- [ ] **步骤 1：创建 uid/update_all.gd**

```gdscript
@tool
extends "res://addons/gdapi/runtime/route_handler.gd"

func handle(params: Dictionary) -> Dictionary:
    var project_path: String = params.get("project_path", "res://")
    if not project_path.begins_with("res://"):
        project_path = "res://" + project_path
    if not project_path.ends_with("/"):
        project_path += "/"

    # 查找所有场景文件
    var scenes := _find_files(project_path, ".tscn")
    var scripts := _find_files(project_path, ".gd") + _find_files(project_path, ".shader") + _find_files(project_path, ".gdshader")

    var success_count := 0
    var error_count := 0

    # 重新保存场景以更新 UID
    for scene_path in scenes:
        var scene = load(scene_path)
        if scene:
            var result := ResourceSaver.save(scene, scene_path)
            if result == OK:
                success_count += 1
            else:
                error_count += 1
        else:
            error_count += 1

    # 检查脚本的 UID 文件
    var missing_uids := 0
    var generated_uids := 0

    for script_path in scripts:
        var uid_path := script_path + ".uid"
        if not FileAccess.file_exists(uid_path):
            missing_uids += 1
            var res = load(script_path)
            if res:
                var result := ResourceSaver.save(res, script_path)
                if result == OK:
                    generated_uids += 1

    return {
        "ok": true,
        "scenes_processed": scenes.size(),
        "scenes_saved": success_count,
        "scenes_errors": error_count,
        "scripts_missing_uids": missing_uids,
        "uids_generated": generated_uids,
    }

func _find_files(path: String, extension: String) -> Array:
    var files := []
    var dir := DirAccess.open(path)
    if not dir:
        return files

    dir.list_dir_begin()
    var file_name := dir.get_next()
    while file_name != "":
        if dir.current_is_dir() and not file_name.begins_with("."):
            files.append_array(_find_files(path + file_name + "/", extension))
        elif file_name.ends_with(extension):
            files.append(path + file_name)
        file_name = dir.get_next()
    dir.list_dir_end()
    return files
```

- [ ] **步骤 2：重新嵌入 addon 到 gdcli 二进制**

运行：`cargo build -p gdcli`
预期：编译成功，新的路由文件被嵌入到二进制中。

- [ ] **步骤 3：运行所有测试**

运行：`cargo test --workspace`
预期：全部通过。

- [ ] **步骤 4：Commit**

```bash
git add -A
git commit -m "feat(gdapi): add uid/update_all route and re-embed addon"
```

---

## 阶段 4 完成标准

执行完所有任务后应达到：

1. `cargo build --workspace` 全部成功
2. `cargo test --workspace` 全部通过
3. `gdapi/addon/routes/` 目录下有 12 个路由文件（不含内置的 ping 和 routes）
4. 路由目录结构：
   ```
   gdapi/addon/routes/
     shared/
       godot/version.gd
       project/info.gd
       uid/get.gd
     editor/
       project/run.gd
       project/stop.gd
       project/debug_output.gd
       scene/create.gd
       scene/add_node.gd
       scene/load_sprite.gd
       scene/save.gd
       scene/export_mesh_library.gd
       uid/update_all.gd
   ```
5. gdcli 二进制已重新嵌入包含新路由的 addon

阶段 4 验证成功后，进入阶段 5（LSP 端口发现）规划。
