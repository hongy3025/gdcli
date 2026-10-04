@tool
extends "res://addons/gdapi/runtime/runtime_route.gd"


func handle(req: GdApiRequest, res: GdApiResponse) -> void:
	dispatch(req, res, "runtime/screenshot/compare")


func doc() -> GdApiRouteDoc:
	return (
		GdApiRouteDoc
		. make("Compare real PNG pixels")
		. desc(
			(
				"Decodes PNGs and computes normalized RGBA pixel errors in the game process. "
				+ "PNG allocation is bounded to 1920x1080 and 3 MiB. "
				+ "Omit actual to compare the current runtime viewport. "
				+ "Dimension mismatch returns matches=false and dimensions_match=false."
			)
		)
		. param("expected", "Dictionary", true, "{path:res://...png} or {data_base64:...}")
		. param("actual", "Dictionary", false, "Second PNG; omitted captures current viewport")
		. param(
			"threshold",
			"float",
			false,
			"0..1 maximum channel error before a pixel differs; default 0"
		)
		. param("max_diff_ratio", "float", false, "0..1 tolerated changed pixel ratio; default 0")
		. param("timeout_ms", "int", false, "1..25000 ms")
		. example(
			(
				'{"expected":{"data_base64":"'
				+ "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1Pe"
				+ "AAAADUlEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC"
				+ '"},"actual":{"data_base64":"'
				+ "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1Pe"
				+ "AAAADUlEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC"
				+ '"}}'
			)
		)
		. returns(
			"Pixel comparison",
			{
				"matches": "bool",
				"dimensions_match": "bool",
				"diff_pixels": "int",
				"diff_ratio": "float",
				"max_error": "float",
				"mean_squared_error": "float",
				"diff_bbox": "{x,y,width,height} or null"
			}
		)
	)
