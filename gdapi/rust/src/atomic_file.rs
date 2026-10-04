use std::fs::{self, OpenOptions};
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

static TEMP_FILE_SEQUENCE: AtomicU64 = AtomicU64::new(0);
const MAX_TEMP_FILE_ATTEMPTS: usize = 256;

#[derive(Debug)]
pub struct TempFile {
    pub path: PathBuf,
    pub target_path: PathBuf,
}

/// Creates and writes a collision-safe temporary file beside a validated target.
///
/// The parent directory and an existing target must resolve within `allowed_root`;
/// protected directories are rejected after canonicalization as well as by the
/// GDScript path guard. `create_new` ensures an existing file or symlink is never
/// truncated or followed.
pub fn create_sibling_temp(
    target: &Path,
    allowed_root: &Path,
    protected_roots: &[PathBuf],
    contents: &[u8],
) -> io::Result<TempFile> {
    if !target.is_absolute() || !allowed_root.is_absolute() {
        return Err(invalid_path_error(
            "target and allowed root must be absolute paths",
        ));
    }
    if !allowed_root.exists() {
        fs::create_dir_all(allowed_root)?;
    }
    let canonical_root = allowed_root.canonicalize()?;
    let canonical_protected = canonicalize_protected_roots(protected_roots)?;
    let target_parent = target
        .parent()
        .ok_or_else(|| invalid_path_error("target has no parent directory"))?;
    let canonical_parent =
        create_and_canonicalize_parent(target_parent, &canonical_root, &canonical_protected)?;

    match fs::symlink_metadata(target) {
        Ok(metadata) => {
            if metadata.file_type().is_symlink() {
                return Err(permission_error("symbolic-link targets are not writable"));
            }
            let canonical_target = target.canonicalize()?;
            ensure_within_root(&canonical_target, &canonical_root)?;
            ensure_not_protected(&canonical_target, &canonical_protected)?;
        }
        Err(error) if error.kind() == io::ErrorKind::NotFound => {}
        Err(error) => return Err(error),
    }

    let file_name = target
        .file_name()
        .ok_or_else(|| invalid_path_error("target has no file name"))?;

    for _ in 0..MAX_TEMP_FILE_ATTEMPTS {
        let sequence = TEMP_FILE_SEQUENCE.fetch_add(1, Ordering::Relaxed);
        let temp_path_io =
            canonical_parent.join(format!(".gdapi-tmp-{}-{sequence}.tmp", std::process::id()));
        match OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&temp_path_io)
        {
            Ok(mut file) => {
                if let Err(error) = file.write_all(contents) {
                    drop(file);
                    let _ = fs::remove_file(&temp_path_io);
                    return Err(error);
                }
                drop(file);
                let temp_path = godot_compatible_path(&temp_path_io);
                let target_path = godot_compatible_path(&canonical_parent.join(file_name));
                return Ok(TempFile {
                    path: temp_path,
                    target_path,
                });
            }
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => continue,
            Err(error) => return Err(error),
        }
    }

    Err(io::Error::new(
        io::ErrorKind::AlreadyExists,
        "could not allocate a unique temporary file",
    ))
}
fn create_and_canonicalize_parent(
    target_parent: &Path,
    root: &Path,
    protected_roots: &[PathBuf],
) -> io::Result<PathBuf> {
    let mut existing = target_parent;
    while !existing.exists() {
        existing = existing
            .parent()
            .ok_or_else(|| invalid_path_error("target parent has no existing ancestor"))?;
    }
    let canonical_existing = existing.canonicalize()?;
    ensure_within_root(&canonical_existing, root)?;
    ensure_not_protected(&canonical_existing, protected_roots)?;

    fs::create_dir_all(target_parent)?;
    let canonical_parent = target_parent.canonicalize()?;
    ensure_within_root(&canonical_parent, root)?;
    ensure_not_protected(&canonical_parent, protected_roots)?;
    Ok(canonical_parent)
}

fn canonicalize_protected_roots(roots: &[PathBuf]) -> io::Result<Vec<PathBuf>> {
    let mut canonical = Vec::with_capacity(roots.len());
    for root in roots {
        match root.canonicalize() {
            Ok(path) => canonical.push(path),
            Err(error) if error.kind() == io::ErrorKind::NotFound => {}
            Err(error) => return Err(error),
        }
    }
    Ok(canonical)
}

fn ensure_not_protected(path: &Path, protected_roots: &[PathBuf]) -> io::Result<()> {
    if protected_roots
        .iter()
        .any(|root| path_starts_with(path, root))
    {
        Err(permission_error("target is in a protected directory"))
    } else {
        Ok(())
    }
}

fn ensure_within_root(path: &Path, root: &Path) -> io::Result<()> {
    if path_starts_with(path, root) {
        Ok(())
    } else {
        Err(permission_error("target escapes its allowed root"))
    }
}

fn path_starts_with(path: &Path, root: &Path) -> bool {
    #[cfg(windows)]
    {
        let path = path.to_string_lossy().to_lowercase();
        let root = root.to_string_lossy().to_lowercase();
        Path::new(&path).starts_with(Path::new(&root))
    }
    #[cfg(not(windows))]
    {
        path.starts_with(root)
    }
}

/// Verifies that an existing path resolves inside the canonical project root.
/// Canonicalization resolves Windows junctions and other filesystem aliases.
pub fn ensure_path_within_root(path: &Path, allowed_root: &Path) -> io::Result<()> {
    if !path.is_absolute() || !allowed_root.is_absolute() {
        return Err(invalid_path_error(
            "path and allowed root must be absolute paths",
        ));
    }
    let canonical_root = allowed_root.canonicalize()?;
    let canonical_path = path.canonicalize()?;
    ensure_within_root(&canonical_path, &canonical_root)
}
#[cfg(windows)]
fn godot_compatible_path(path: &Path) -> PathBuf {
    let value = path.to_string_lossy();
    if let Some(suffix) = value.strip_prefix("\\\\?\\UNC\\") {
        PathBuf::from(format!("\\\\{suffix}"))
    } else if let Some(suffix) = value.strip_prefix("\\\\?\\") {
        PathBuf::from(suffix)
    } else {
        path.to_path_buf()
    }
}

#[cfg(not(windows))]
fn godot_compatible_path(path: &Path) -> PathBuf {
    path.to_path_buf()
}

fn invalid_path_error(message: &str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidInput, message)
}

fn permission_error(message: &str) -> io::Error {
    io::Error::new(io::ErrorKind::PermissionDenied, message)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn make_temp_dir() -> PathBuf {
        let stamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("clock should be after unix epoch")
            .as_nanos();
        let path =
            std::env::temp_dir().join(format!("gdapi-atomic-file-{}-{stamp}", std::process::id()));
        fs::create_dir(&path).expect("test directory should be unique");
        path
    }

    #[test]
    fn preserves_legacy_sidecar_and_writes_unique_temp_file() {
        let root = make_temp_dir();
        let target = root.join("target.txt");
        let mut legacy_sidecar = target.as_os_str().to_os_string();
        legacy_sidecar.push(".gdcli-tmp");
        let legacy_sidecar = PathBuf::from(legacy_sidecar);
        fs::write(&legacy_sidecar, b"keep this user file").unwrap();

        let temp = create_sibling_temp(&target, &root, &[], b"new target contents").unwrap();
        assert_ne!(temp.path, legacy_sidecar);
        assert_eq!(fs::read(&legacy_sidecar).unwrap(), b"keep this user file");
        assert_eq!(fs::read(&temp.path).unwrap(), b"new target contents");
        assert_eq!(
            temp.target_path.parent().unwrap().canonicalize().unwrap(),
            root.canonicalize().unwrap()
        );
        assert_eq!(temp.target_path.file_name(), target.file_name());
        fs::remove_file(temp.path).unwrap();
        fs::remove_file(legacy_sidecar).unwrap();
        fs::remove_dir(root).unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn preserves_symlinked_legacy_sidecar_without_modifying_external_file() {
        use std::os::unix::fs::symlink;

        let root = make_temp_dir();
        let outside = root.with_extension("outside");
        fs::create_dir(&outside).unwrap();
        let outside_file = outside.join("keep.txt");
        fs::write(&outside_file, b"outside sentinel").unwrap();
        let target = root.join("target.txt");
        let mut sidecar_name = target.as_os_str().to_os_string();
        sidecar_name.push(".gdcli-tmp");
        let legacy_sidecar = PathBuf::from(sidecar_name);
        symlink(&outside_file, &legacy_sidecar).unwrap();

        let temp = create_sibling_temp(&target, &root, &[], b"new contents").unwrap();
        assert!(fs::symlink_metadata(&legacy_sidecar)
            .unwrap()
            .file_type()
            .is_symlink());
        assert_eq!(fs::read(&outside_file).unwrap(), b"outside sentinel");
        assert_eq!(fs::read(&temp.path).unwrap(), b"new contents");

        fs::remove_file(temp.path).unwrap();
        fs::remove_file(legacy_sidecar).unwrap();
        fs::remove_file(outside_file).unwrap();
        fs::remove_dir(outside).unwrap();
        fs::remove_dir(root).unwrap();
    }

    #[test]
    fn creates_missing_parent_directories_inside_allowed_root() {
        let root = make_temp_dir();
        let target = root.join("nested").join("deep").join("target.txt");

        let temp = create_sibling_temp(&target, &root, &[], b"nested contents").unwrap();
        assert!(target.parent().unwrap().is_dir());
        assert_eq!(fs::read(&temp.path).unwrap(), b"nested contents");
        assert_eq!(
            temp.target_path.parent().unwrap().canonicalize().unwrap(),
            target.parent().unwrap().canonicalize().unwrap()
        );
        assert_eq!(temp.target_path.file_name(), target.file_name());

        fs::remove_file(temp.path).unwrap();
        fs::remove_dir_all(root).unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn rejects_symlink_into_protected_directory() {
        use std::os::unix::fs::symlink;

        let root = make_temp_dir();
        let protected = root.join("addons").join("gdapi");
        fs::create_dir_all(&protected).unwrap();
        let alias = root.join("safe_alias");
        symlink(&protected, &alias).unwrap();

        let result = create_sibling_temp(
            &alias.join("target.txt"),
            &root,
            std::slice::from_ref(&protected),
            b"must not be written",
        );
        assert_eq!(result.unwrap_err().kind(), io::ErrorKind::PermissionDenied);
        assert!(!protected.join("target.txt").exists());

        fs::remove_file(&alias).unwrap();
        fs::remove_dir_all(root).unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn rejects_parent_symlink_that_escapes_allowed_root() {
        use std::os::unix::fs::symlink;

        let root = make_temp_dir();
        let outside = root.with_extension("outside");
        fs::create_dir(&outside).unwrap();
        let outside_file = outside.join("keep.txt");
        fs::write(&outside_file, b"outside sentinel").unwrap();
        let link = root.join("linked");
        symlink(&outside, &link).unwrap();

        let result = create_sibling_temp(&link.join("target.txt"), &root, &[], b"overwrite");
        assert_eq!(result.unwrap_err().kind(), io::ErrorKind::PermissionDenied);
        assert_eq!(fs::read(&outside_file).unwrap(), b"outside sentinel");

        fs::remove_file(&outside_file).unwrap();
        fs::remove_dir(&outside).unwrap();
        fs::remove_file(&link).unwrap();
        fs::remove_dir(root).unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn rejects_target_symlink_without_modifying_external_file() {
        use std::os::unix::fs::symlink;

        let root = make_temp_dir();
        let outside = root.with_extension("outside");
        fs::create_dir(&outside).unwrap();
        let outside_file = outside.join("keep.txt");
        fs::write(&outside_file, b"outside sentinel").unwrap();
        let target = root.join("target.txt");
        symlink(&outside_file, &target).unwrap();

        let result = create_sibling_temp(&target, &root, &[], b"overwrite");
        assert_eq!(result.unwrap_err().kind(), io::ErrorKind::PermissionDenied);
        assert_eq!(fs::read(&outside_file).unwrap(), b"outside sentinel");

        fs::remove_file(&target).unwrap();
        fs::remove_file(&outside_file).unwrap();
        fs::remove_dir(&outside).unwrap();
        fs::remove_dir(root).unwrap();
    }
}
