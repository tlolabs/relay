use serde::{Deserialize, Serialize};
use std::{
    fs,
    path::{Path, PathBuf},
    sync::atomic::{AtomicU64, Ordering},
    time::{SystemTime, UNIX_EPOCH},
};
pub fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64
}
pub fn identifier() -> String {
    static NEXT: AtomicU64 = AtomicU64::new(0);
    format!(
        "{}-{}-{}",
        now(),
        std::process::id(),
        NEXT.fetch_add(1, Ordering::Relaxed)
    )
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct Fingerprint {
    pub device: u64,
    pub inode: u64,
    pub size: u64,
    pub modified_ns: String,
}
impl Fingerprint {
    pub fn read(path: &Path) -> Result<Self, String> {
        let meta = fs::symlink_metadata(path).map_err(|e| format!("{}: {e}", path.display()))?;
        if !meta.is_file() {
            return Err(format!("Not a regular file: {}", path.display()));
        }
        use std::os::unix::fs::MetadataExt;
        Ok(Self {
            device: meta.dev(),
            inode: meta.ino(),
            size: meta.len(),
            modified_ns: meta
                .modified()
                .ok()
                .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
                .map(|d| d.as_nanos().to_string())
                .unwrap_or_default(),
        })
    }
    pub fn same_object(&self, other: &Self) -> bool {
        self.device == other.device && self.inode == other.inode
    }
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Default)]
#[serde(default)]
pub struct Identity {
    pub kind: String,
    pub title: String,
    pub year: Option<u16>,
    pub season: Option<u32>,
    pub episode: Option<u32>,
    pub episode_title: String,
    pub tmdb_id: Option<u64>,
    pub release_date: Option<String>,
    pub include_year: bool,
}
impl Identity {
    pub fn valid(&self) -> bool {
        !clean(&self.title).is_empty()
            && self.year.is_none_or(|y| (1880..=2200).contains(&y))
            && match self.kind.as_str() {
                "tv" => {
                    self.season.is_some_and(|s| s <= 10000)
                        && self.episode.is_some_and(|e| e > 0 && e <= 100000)
                }
                "movie" => self.year.is_some_and(|y| (1880..=2200).contains(&y)),
                _ => false,
            }
    }
    pub fn group(&self) -> String {
        if self.kind == "movie" {
            "Movies".into()
        } else if self.title.is_empty() {
            "Needs identity".into()
        } else {
            self.title.clone()
        }
    }
    pub fn basename(&self) -> Result<String, String> {
        if !self.valid() {
            return Err("Confirm a title and movie year or TV season/episode first".into());
        }
        let title = clean(&self.title);
        let name = if self.kind == "movie" {
            format!("{} ({})", title, self.year.unwrap())
        } else {
            let year = if self.include_year {
                self.year.map(|y| format!(" ({y})")).unwrap_or_default()
            } else {
                String::new()
            };
            let suffix = if self.episode_title.trim().is_empty() {
                String::new()
            } else {
                format!(" - {}", clean(&self.episode_title))
            };
            format!(
                "{title}{year} - S{:02}E{:02}{suffix}",
                self.season.unwrap(),
                self.episode.unwrap()
            )
        };
        if name.as_bytes().len() > 220 {
            return Err("The proposed filename is too long; shorten the reviewed title".into());
        }
        Ok(name)
    }
}
pub fn clean(value: &str) -> String {
    let text: String = value
        .chars()
        .map(|c| {
            if c == '/' || c == ':' || c == '\0' || c.is_control() {
                ' '
            } else {
                c
            }
        })
        .collect();
    text.split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .trim_matches('.')
        .trim()
        .to_string()
}
pub fn normalized(value: &str) -> String {
    value
        .chars()
        .flat_map(char::to_lowercase)
        .filter(|c| c.is_alphanumeric())
        .collect()
}
pub fn parse_identity(stem: &str) -> Identity {
    let lower = stem.to_lowercase();
    let bytes = lower.as_bytes();
    for i in 0..bytes.len() {
        if bytes[i] != b's' || i > 0 && bytes[i - 1].is_ascii_alphanumeric() {
            continue;
        }
        let mut j = i + 1;
        while j < bytes.len() && bytes[j].is_ascii_digit() {
            j += 1;
        }
        if j == i + 1 || j >= bytes.len() || bytes[j] != b'e' {
            continue;
        }
        let split = j;
        j += 1;
        let start = j;
        while j < bytes.len() && bytes[j].is_ascii_digit() {
            j += 1;
        }
        if start == j {
            continue;
        }
        // Match byte boundaries in the original Unicode string through the ASCII
        // marker, not lowercased offsets (Unicode lowercasing can change length).
        let marker = &lower[i..j];
        if let Some(original_index) = stem.to_ascii_lowercase().find(marker) {
            let title = stem[..original_index]
                .trim_matches(|c: char| c.is_whitespace() || c == '-' || c == '–')
                .to_string();
            let mut result = Identity {
                kind: "tv".into(),
                title,
                season: lower[i + 1..split].parse().ok(),
                episode: lower[start..j].parse().ok(),
                episode_title: stem[original_index + marker.len()..]
                    .trim_matches(|c: char| c.is_whitespace() || c == '-' || c == '–')
                    .to_string(),
                ..Default::default()
            };
            if let Some((name, year)) = year_suffix(&result.title) {
                result.title = name;
                result.year = Some(year);
                result.include_year = true;
            }
            let remainder = lower[j..].trim_start_matches([' ', '-', '–']);
            if remainder.starts_with('e')
                && remainder.as_bytes().get(1).is_some_and(u8::is_ascii_digit)
                || lower.as_bytes().get(j) == Some(&b'-')
                    && lower.as_bytes().get(j + 1).is_some_and(u8::is_ascii_digit)
            {
                result.episode = None;
            }
            return result;
        }
    }
    if let Some((title, year)) = year_suffix(stem) {
        return Identity {
            kind: "movie".into(),
            title,
            year: Some(year),
            ..Default::default()
        };
    }
    Identity {
        episode_title: stem.into(),
        ..Default::default()
    }
}
fn year_suffix(stem: &str) -> Option<(String, u16)> {
    if let Some(start) = stem.rfind('(') {
        let suffix = &stem[start + 1..];
        if suffix.len() >= 5
            && suffix.as_bytes()[4] == b')'
            && suffix.as_bytes()[..4].iter().all(u8::is_ascii_digit)
        {
            let tail = suffix[5..].trim();
            if tail.is_empty() || tail.starts_with('-') {
                let y = suffix[..4].parse::<u16>().ok()?;
                if (1880..=2200).contains(&y) {
                    return Some((stem[..start].trim().into(), y));
                }
            }
        }
    }
    None
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Subtitle {
    pub id: String,
    pub original_path: PathBuf,
    pub current_path: PathBuf,
    pub fingerprint: Fingerprint,
    pub language: String,
    pub selected: bool,
    pub retained_path: Option<PathBuf>,
    pub target_path: Option<PathBuf>,
    pub published_path: Option<PathBuf>,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Job {
    #[serde(default)]
    pub direct: crate::direct::DirectDraft,
    pub id: String,
    pub original_path: PathBuf,
    pub current_path: PathBuf,
    pub fingerprint: Fingerprint,
    pub identity: Identity,
    pub subtitles: Vec<Subtitle>,
    pub included: bool,
    pub revision: u64,
    pub state: String,
    pub message: String,
    pub created_ms: u64,
    pub updated_ms: u64,
    pub prepared_path: Option<PathBuf>,
    pub batch_id: Option<String>,
    pub approved_revision: Option<u64>,
    pub iflicks_id: Option<String>,
    pub process_identity: Option<String>,
    pub progress: Option<i64>,
    pub iflicks_status: Option<String>,
    pub output_path: Option<PathBuf>,
    pub output_fingerprint: Option<Fingerprint>,
    pub output_attested_ms: Option<u64>,
}
impl Job {
    pub fn editable(&self) -> bool {
        matches!(
            self.state.as_str(),
            "needs_review" | "excluded" | "source_changed"
        )
    }
    pub fn video_target(&self) -> Result<PathBuf, String> {
        let stem = self.identity.basename()?;
        let ext = self
            .current_path
            .extension()
            .and_then(|e| e.to_str())
            .ok_or("Missing video extension")?;
        Ok(self.current_path.with_file_name(format!("{stem}.{ext}")))
    }
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Config {
    pub roots: Vec<PathBuf>,
    pub recursive: bool,
    pub output_folder: PathBuf,
}
pub fn video(path: &Path) -> bool {
    path.extension().and_then(|s| s.to_str()).is_some_and(|e| {
        matches!(
            e.to_ascii_lowercase().as_str(),
            "mp4" | "m4v" | "mkv" | "mov" | "avi" | "webm" | "ts"
        )
    })
}
