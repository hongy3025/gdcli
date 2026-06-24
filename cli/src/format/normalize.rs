//! R1/R2/R3/R4 启发式预处理。详见设计文档 §4。

use serde_json::{Map, Value};

/// 递归应用 R1/R2/R3/R4 变换。
pub fn normalize(v: Value) -> Value {
    match v {
        Value::Array(arr) => {
            let arr: Vec<Value> = arr.into_iter().map(normalize).collect();
            if let Some(coerced) = try_coerce_with_r1(&arr) {
                Value::Array(coerced)
            } else {
                Value::Array(arr)
            }
        }
        Value::Object(map) => {
            let mut out = Map::new();
            if let Some(v) = map.get("ok") {
                out.insert("ok".to_string(), normalize(v.clone()));
            }
            for (k, v) in map {
                if k != "ok" {
                    out.insert(k, normalize(v));
                }
            }
            Value::Object(out)
        }
        primitive => primitive,
    }
}

fn try_coerce_with_r1(arr: &[Value]) -> Option<Vec<Value>> {
    if arr.is_empty() {
        return None;
    }
    let first = arr.first()?.as_object()?;
    let keys: Vec<&String> = first.keys().collect();

    let all_match = arr.iter().all(|v| {
        v.as_object()
            .map(|o| o.len() == keys.len() && keys.iter().all(|k| o.contains_key(k.as_str())))
            .unwrap_or(false)
    });
    if !all_match {
        return None;
    }

    let all_coercible = arr.iter().all(|v| {
        v.as_object()
            .map(|o| o.values().all(is_primitive_or_coercible))
            .unwrap_or(false)
    });
    if !all_coercible {
        return None;
    }

    let coerced: Vec<Value> = arr
        .iter()
        .map(|v| {
            let obj = v.as_object().expect("checked above");
            let new_map: Map<String, Value> = obj
                .iter()
                .map(|(k, val)| (k.clone(), coerce_value(val)))
                .collect();
            Value::Object(new_map)
        })
        .collect();
    Some(coerced)
}

fn is_primitive(v: &Value) -> bool {
    !v.is_object() && !v.is_array()
}

fn is_primitive_or_coercible(v: &Value) -> bool {
    if is_primitive(v) {
        return true;
    }
    if let Value::Array(inner) = v {
        if inner.is_empty() {
            return true;
        }
        if inner.len() == 1 && is_primitive(&inner[0]) {
            return true;
        }
    }
    false
}

fn coerce_value(v: &Value) -> Value {
    match v {
        Value::Array(inner) if inner.is_empty() => Value::String(String::new()),
        Value::Array(inner) if inner.len() == 1 && is_primitive(&inner[0]) => inner[0].clone(),
        other => other.clone(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn n(v: Value) -> Value {
        normalize(v)
    }

    #[test]
    fn r3_uniform_array_passes_through_for_encoder() {
        let v = json!([{"a":1,"b":2},{"a":3,"b":4}]);
        let out = n(v.clone());
        assert_eq!(out, v, "uniform primitive-only array should be unchanged");
    }

    #[test]
    fn r1_empty_array_becomes_empty_string() {
        let v = json!([{"path":"ping","params":[]},{"path":"help","params":["x"]}]);
        let out = n(v);
        assert_eq!(
            out,
            json!([{"path":"ping","params":""},{"path":"help","params":"x"}])
        );
    }

    #[test]
    fn r1_null_unchanged_in_uniform_array() {
        let v = json!([{"a":1,"b":null},{"a":2,"b":3}]);
        let out = n(v.clone());
        assert_eq!(out, v);
    }

    #[test]
    fn r2_kv_array_unchanged() {
        let v = json!([{"item":"代码","value":"600519"},{"item":"最新价","value":"1326.0"}]);
        let out = n(v.clone());
        assert_eq!(out, v);
    }

    #[test]
    fn nested_object_recurses() {
        let v = json!({"outer": [{"inner": []}, {"inner": ["x"]}]});
        let out = n(v);
        assert_eq!(out, json!({"outer": [{"inner": ""}, {"inner": "x"}]}));
    }

    #[test]
    fn non_uniform_array_unchanged() {
        let v = json!([{"a":1}, {"b":2}]);
        let out = n(v.clone());
        assert_eq!(out, v);
    }

    #[test]
    fn array_with_nested_objects_unchanged() {
        let v = json!([{"a":1,"sub":{"x":2}}, {"a":2,"sub":{"x":3}}]);
        let out = n(v.clone());
        assert_eq!(out, v);
    }

    #[test]
    fn ok_field_moved_to_front() {
        let v = json!({"gdapi_version":"0.2.0","ok":true,"editor_version":"4.3"});
        let out = n(v);
        let keys: Vec<&str> = out.as_object().unwrap().keys().map(|s| s.as_str()).collect();
        assert_eq!(keys, vec!["ok", "gdapi_version", "editor_version"]);
    }

    #[test]
    fn nested_object_ok_reordered() {
        let v = json!({"data":{"version":"1.0","ok":true}});
        let out = n(v);
        let inner = out.get("data").unwrap().as_object().unwrap();
        let keys: Vec<&str> = inner.keys().map(|s| s.as_str()).collect();
        assert_eq!(keys, vec!["ok", "version"]);
    }
}
