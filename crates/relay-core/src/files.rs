use crate::model::*;
use std::{
    ffi::CString,
    fs,
    io::Write,
    os::unix::ffi::OsStrExt,
    path::{Path, PathBuf},
};
#[cfg(target_os = "macos")]
unsafe extern "C" {
    fn renamex_np(from: *const std::ffi::c_char, to: *const std::ffi::c_char, flags: u32) -> i32;
}
pub fn rename_exclusive(from: &Path, to: &Path) -> Result<(), String> {
    if from == to {
        return Ok(());
    }
    #[cfg(target_os = "macos")]
    {
        let a = CString::new(from.as_os_str().as_bytes()).map_err(|e| e.to_string())?;
        let b = CString::new(to.as_os_str().as_bytes()).map_err(|e| e.to_string())?;
        if unsafe { renamex_np(a.as_ptr(), b.as_ptr(), 4) } != 0 {
            return Err(format!(
                "Cannot rename {} to {}: {}",
                from.display(),
                to.display(),
                std::io::Error::last_os_error()
            ));
        }
        sync_parent(to)?;
        Ok(())
    }
    #[cfg(not(target_os = "macos"))]
    {
        fs::hard_link(from, to).map_err(|e| e.to_string())?;
        fs::remove_file(from).map_err(|e| e.to_string())?;
        Ok(())
    }
}
pub fn sync_parent(path: &Path) -> Result<(), String> {
    if let Some(p) = path.parent() {
        fs::File::open(p)
            .and_then(|f| f.sync_all())
            .map_err(|e| format!("Cannot sync {}: {e}", p.display()))?;
    }
    Ok(())
}
pub fn subtitle_bytes(path: &Path) -> Result<Vec<u8>, String> {
    let fp = Fingerprint::read(path)?;
    if fp.size == 0 || fp.size > 32 * 1024 * 1024 {
        return Err("Subtitle must be nonempty and smaller than 32 MiB".into());
    }
    if path
        .extension()
        .and_then(|e| e.to_str())
        .is_none_or(|e| !e.eq_ignore_ascii_case("srt"))
    {
        return Err("Choose an SRT subtitle".into());
    }
    fs::read(path).map_err(|e| e.to_string())
}
pub fn stage(bytes: &[u8], destination: &Path) -> Result<(PathBuf, Fingerprint), String> {
    let temp = destination.with_file_name(format!(".relay-{}.tmp", identifier()));
    let outcome = (|| {
        let mut file = fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&temp)
            .map_err(|e| e.to_string())?;
        file.write_all(bytes).map_err(|e| e.to_string())?;
        file.sync_all().map_err(|e| e.to_string())?;
        if fs::read(&temp).map_err(|e| e.to_string())? != bytes {
            return Err("Subtitle copy verification failed".into());
        }
        Ok((temp.clone(), Fingerprint::read(&temp)?))
    })();
    if outcome.is_err() {
        let _ = fs::remove_file(&temp);
    }
    outcome
}
pub fn publish(bytes: &[u8], destination: &Path) -> Result<(), String> {
    let (temp, _) = stage(bytes, destination)?;
    let result = rename_exclusive(&temp, destination);
    if temp.exists() {
        let _ = fs::remove_file(temp);
    }
    result
}
pub fn discover_paths(config: &Config) -> Result<Vec<PathBuf>, String> {
    let mut result = Vec::new();
    let mut pending = config.roots.clone();
    let mut roots = std::collections::BTreeSet::new();
    while let Some(dir) = pending.pop() {
        let canonical =
            fs::canonicalize(&dir).map_err(|e| format!("Cannot scan {}: {e}", dir.display()))?;
        if !roots.insert(canonical.clone()) {
            continue;
        }
        for entry in fs::read_dir(&canonical).map_err(|e| e.to_string())? {
            let entry = entry.map_err(|e| e.to_string())?;
            let path = entry.path();
            let name = entry.file_name().to_string_lossy().into_owned();
            if name.starts_with('.')
                || name.ends_with(".app")
                || name.ends_with(".downiepart")
                || name.starts_with("RELAY-observer-")
            {
                continue;
            }
            let meta = fs::symlink_metadata(&path).map_err(|e| e.to_string())?;
            if meta.file_type().is_symlink() {
                continue;
            }
            if meta.is_dir() && config.recursive {
                pending.push(path);
            } else if meta.is_file() && video(&path) {
                result.push(path);
            }
        }
    }
    result.sort();
    Ok(result)
}
pub fn companions(video: &Path) -> Result<Vec<Subtitle>, String> {
    let stem = video
        .file_stem()
        .and_then(|s| s.to_str())
        .ok_or("A filename is not valid UTF-8; rename it manually before intake")?;
    let mut result = Vec::new();
    for entry in fs::read_dir(video.parent().unwrap()).map_err(|e| e.to_string())? {
        let path = entry.map_err(|e| e.to_string())?.path();
        if path
            .extension()
            .and_then(|e| e.to_str())
            .is_none_or(|e| !e.eq_ignore_ascii_case("srt"))
        {
            continue;
        }
        let name = path.file_stem().and_then(|s| s.to_str()).unwrap_or("");
        let language = if name == stem {
            Some("en")
        } else {
            name.strip_prefix(&format!("{stem}."))
        };
        if let Some(language) = language.filter(|l| valid_language(l)) {
            let fp = Fingerprint::read(&path)?;
            result.push(Subtitle {
                id: identifier(),
                original_path: path.clone(),
                current_path: path.clone(),
                fingerprint: fp,
                language: language.into(),
                selected: true,
                retained_path: None,
                target_path: None,
                published_path: None,
            });
        }
    }
    let mut languages = std::collections::BTreeMap::new();
    for s in &result {
        *languages.entry(s.language.clone()).or_insert(0) += 1;
    }
    for s in &mut result {
        if languages[&s.language] > 1 {
            s.selected = false;
        }
    }
    result.sort_by(|a, b| a.current_path.cmp(&b.current_path));
    Ok(result)
}
pub fn valid_language(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 24
        && value
            .bytes()
            .all(|c| c.is_ascii_alphanumeric() || c == b'.' || c == b'-')
        && !value.starts_with('.')
        && !value.ends_with('.')
        && !value.contains("..")
}

pub fn intermediate(target: &Path, id: &str) -> PathBuf {
    target.with_file_name(format!(".relay-rename-{id}.tmp"))
}
pub fn case_alias(source: &Path, target: &Path) -> bool {
    if source == target
        || source.to_string_lossy().to_lowercase() != target.to_string_lossy().to_lowercase()
    {
        return false;
    }
    let (Ok(a), Ok(b)) = (Fingerprint::read(source), Fingerprint::read(target)) else {
        return false;
    };
    if !a.same_object(&b) {
        return false;
    }
    // On a case-sensitive volume, separate case-differing hard links are two
    // entries and must remain a collision, even when their inodes are equal.
    !fs::read_dir(source.parent().unwrap())
        .ok()
        .is_some_and(|entries| {
            entries
                .filter_map(Result::ok)
                .any(|entry| entry.file_name() == target.file_name().unwrap())
        })
}
pub fn rename_owned(source: &Path, target: &Path, id: &str) -> Result<(), String> {
    if case_alias(source, target) {
        let temporary = intermediate(target, id);
        rename_exclusive(source, &temporary)?;
        rename_exclusive(&temporary, target)
    } else {
        rename_exclusive(source, target)
    }
}
