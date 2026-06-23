use std::path::{Path, PathBuf};

const MAX_DEPTH: usize = 5;

pub fn find_root(from: &Path) -> Option<PathBuf> {
    let mut dir = if from.is_absolute() {
        from.to_path_buf()
    } else {
        std::env::current_dir().ok()?.join(from)
    };
    if dir.is_file() {
        dir = dir.parent()?.to_path_buf();
    }
    for _ in 0..=MAX_DEPTH {
        let candidate = dir.join("project.godot");
        if candidate.is_file() {
            return Some(dir);
        }
        if !dir.pop() {
            break;
        }
    }
    None
}

pub fn resolve_project_root(explicit: Option<&Path>) -> Result<PathBuf, String> {
    match explicit {
        Some(p) => {
            let abs = if p.is_absolute() {
                p.to_path_buf()
            } else {
                std::env::current_dir()
                    .map_err(|e| format!("cannot get cwd: {}", e))?
                    .join(p)
            };
            if abs.join("project.godot").is_file() {
                Ok(abs)
            } else {
                Err(format!(
                    "not a Godot project (no project.godot in {})",
                    abs.display()
                ))
            }
        }
        None => {
            let cwd = std::env::current_dir()
                .map_err(|e| format!("cannot get cwd: {}", e))?;
            find_root(&cwd).ok_or_else(|| {
                format!(
                    "no Godot project found from {} (searched up {} levels). \
                     Use --project <path> or run from within a Godot project.",
                    cwd.display(),
                    MAX_DEPTH
                )
            })
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use tempfile::TempDir;

    #[test]
    fn find_root_in_current_dir() {
        let dir = TempDir::new().unwrap();
        fs::write(dir.path().join("project.godot"), "").unwrap();
        assert_eq!(find_root(dir.path()), Some(dir.path().to_path_buf()));
    }

    #[test]
    fn find_root_in_parent() {
        let dir = TempDir::new().unwrap();
        let sub = dir.path().join("src").join("scripts");
        fs::create_dir_all(&sub).unwrap();
        fs::write(dir.path().join("project.godot"), "").unwrap();
        assert_eq!(find_root(&sub), Some(dir.path().to_path_buf()));
    }

    #[test]
    fn find_root_max_depth() {
        let dir = TempDir::new().unwrap();
        let mut deep = dir.path().to_path_buf();
        for _ in 0..6 {
            deep = deep.join("a");
        }
        fs::create_dir_all(&deep).unwrap();
        fs::write(dir.path().join("project.godot"), "").unwrap();
        assert_eq!(find_root(&deep), None);
    }

    #[test]
    fn find_root_not_found() {
        let dir = TempDir::new().unwrap();
        assert_eq!(find_root(dir.path()), None);
    }

    #[test]
    fn find_root_file_path() {
        let dir = TempDir::new().unwrap();
        fs::write(dir.path().join("project.godot"), "").unwrap();
        let file = dir.path().join("main.gd");
        fs::write(&file, "").unwrap();
        assert_eq!(find_root(&file), Some(dir.path().to_path_buf()));
    }

    #[test]
    fn resolve_explicit_valid() {
        let dir = TempDir::new().unwrap();
        fs::write(dir.path().join("project.godot"), "").unwrap();
        let result = resolve_project_root(Some(dir.path()));
        assert!(result.is_ok());
        assert_eq!(result.unwrap(), dir.path());
    }

    #[test]
    fn resolve_explicit_invalid() {
        let dir = TempDir::new().unwrap();
        let result = resolve_project_root(Some(dir.path()));
        assert!(result.is_err());
        assert!(result.unwrap_err().contains("not a Godot project"));
    }

    #[test]
    fn resolve_auto_not_found() {
        let dir = TempDir::new().unwrap();
        let original_cwd = std::env::current_dir().unwrap();
        std::env::set_current_dir(dir.path()).unwrap();
        let result = resolve_project_root(None);
        std::env::set_current_dir(original_cwd).unwrap();
        assert!(result.is_err());
        assert!(result.unwrap_err().contains("no Godot project found"));
    }
}
