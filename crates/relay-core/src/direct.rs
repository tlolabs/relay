//! Direct media jobs: input bytes remain untouched; only owned staging files are writable.
use crate::{files::*, model::*, workflow::Core};
use mp4ameta::{Data, DataIdent, Fourcc, FreeformIdent, ReadConfig, Tag, WriteConfig};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{
    collections::{BTreeMap, BTreeSet},
    fs,
    io::{Read, Seek, SeekFrom},
    path::{Path, PathBuf},
};
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(default)]
pub struct DirectDraft {
    pub metadata: BTreeMap<String, String>,
    pub overrides: BTreeSet<String>,
    pub filename: String,
    pub destination: String,
    pub streaming: bool,
    pub trash_source: bool,
    pub embed_subtitles: bool,
    pub artwork_path: String,
    pub artwork_fingerprint: Option<Fingerprint>,
    pub artwork_url: String,
    pub tracks: Vec<TrackChoice>,
    pub inspection: Value,
    pub temporary: Option<PathBuf>,
    pub temporary_identity: Option<Fingerprint>,
    pub target: Option<PathBuf>,
    pub receipt: Option<Fingerprint>,
    pub trash_path: Option<String>,
    pub backend: bool,
}
impl Default for DirectDraft {
    fn default() -> Self {
        Self {
            metadata: BTreeMap::new(),
            overrides: BTreeSet::new(),
            filename: String::new(),
            destination: String::new(),
            streaming: true,
            trash_source: true,
            embed_subtitles: false,
            artwork_path: String::new(),
            artwork_fingerprint: None,
            artwork_url: String::new(),
            tracks: vec![],
            inspection: Value::Null,
            temporary: None,
            temporary_identity: None,
            target: None,
            receipt: None,
            trash_path: None,
            backend: false,
        }
    }
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct TrackChoice {
    pub index: i64,
    pub enabled: bool,
    pub language: String,
    pub default: bool,
    pub forced: bool,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(default)]
pub struct Naming {
    pub tv: String,
    pub movie: String,
    pub suffixes: BTreeMap<String, String>,
}
impl Default for Naming {
    fn default() -> Self {
        let mut suffixes = BTreeMap::new();
        for q in ["SD", "HD 720p", "HD 1080p", "4K"] {
            for c in ["H.264", "HEVC"] {
                suffixes.insert(format!("{q} {c}"), format!("{q} {c} DL"));
            }
        }
        Self {
            tv: "{show} – s{season:02}e{episode:02} – {name}-{comment}.mp4".into(),
            movie: "{name} ({year})-{comment}.mp4".into(),
            suffixes,
        }
    }
}
pub fn quality(height: u64) -> &'static str {
    if height > 1080 {
        "4K"
    } else if height > 720 {
        "HD 1080p"
    } else if height > 560 {
        "HD 720p"
    } else {
        "SD"
    }
}
fn job_quality(job: &Job) -> &'static str {
    match job.direct.metadata.get("definition").map(String::as_str) {
        Some("0") => "SD",
        Some("1") => "HD 720p",
        Some("2") => "HD 1080p",
        Some("3") => "4K",
        _ => quality(
            job.direct.inspection["rule_media"][0]["height"]
                .as_u64()
                .unwrap_or(0),
        ),
    }
}
pub fn filename(job: &Job, naming: &Naming) -> Result<String, String> {
    if !job.identity.valid() {
        return Err("Confirm title, year or episode identity first".into());
    }
    if !job.direct.filename.is_empty() {
        return valid_filename(&job.direct.filename);
    }
    let media = &job.direct.inspection["rule_media"];
    let video = media
        .as_array()
        .and_then(|a| a.first())
        .ok_or("Inspect the video before previewing its filename")?;
    let codec = match video["format"].as_str() {
        Some("AVC") => "H.264",
        Some("HEVC") => "HEVC",
        _ => return Err("Only H.264 and HEVC passthrough are supported".into()),
    };
    let key = format!("{} {codec}", job_quality(job));
    let suffix = naming
        .suffixes
        .get(&key)
        .ok_or("Missing quality/codec suffix setting")?;
    let comment = if job.direct.overrides.contains("comment") {
        job.direct.metadata.get("comment").unwrap_or(suffix)
    } else {
        job.direct
            .metadata
            .get("comment")
            .filter(|s| !s.is_empty() && !s.starts_with("Information courtesy of"))
            .unwrap_or(suffix)
    };
    let i = &job.identity;
    let title = if i.kind == "tv" {
        &i.episode_title
    } else {
        &i.title
    };
    let mut template = if i.kind == "tv" {
        naming.tv.clone()
    } else {
        naming.movie.clone()
    };
    let show = if i.kind == "tv" && i.include_year && !template.contains("{year}") {
        i.year
            .map(|y| format!("{} ({y})", i.title))
            .unwrap_or_else(|| i.title.clone())
    } else {
        i.title.clone()
    };
    for (key, value) in [
        ("{show}", show),
        ("{name}", title.clone()),
        ("{year}", i.year.map(|n| n.to_string()).unwrap_or_default()),
        ("{season:02}", format!("{:02}", i.season.unwrap_or(0))),
        ("{episode:02}", format!("{:02}", i.episode.unwrap_or(0))),
        ("{season}", i.season.unwrap_or(0).to_string()),
        ("{episode}", i.episode.unwrap_or(0).to_string()),
        ("{comment}", comment.clone()),
    ] {
        template = template.replace(key, &clean(&value));
    }
    if template.contains('{') || template.contains('}') {
        return Err("Unknown naming template token".into());
    }
    valid_filename(&template)
}
fn valid_filename(s: &str) -> Result<String, String> {
    if s.is_empty()
        || s.len() > 245
        || s.starts_with('.')
        || s.contains(['/', ':', '\0'])
        || s.chars().any(char::is_control)
        || !s.to_lowercase().ends_with(".mp4")
    {
        Err("Use a plain MP4 filename, without path separators, shorter than 246 bytes".into())
    } else {
        Ok(s.into())
    }
}
// Shared field identifiers map to actual atoms; provider IDs never masquerade as Apple IDs.
pub const TEXT_FIELDS: &[(&str, [u8; 4])] = &[
    ("name", *b"\xa9nam"),
    ("show", *b"tvsh"),
    ("tagline", *b"desc"),
    ("description", *b"ldes"),
    ("releaseDate", *b"\xa9day"),
    ("genre", *b"\xa9gen"),
    ("comment", *b"\xa9cmt"),
    ("album", *b"\xa9alb"),
    ("artist", *b"\xa9ART"),
    ("albumArtist", *b"aART"),
    ("composer", *b"\xa9wrt"),
    ("network", *b"tvnn"),
    ("sortAlbum", *b"soal"),
    ("sortAlbumArtist", *b"soaa"),
    ("sortArtist", *b"soar"),
    ("sortComposer", *b"soco"),
    ("sortName", *b"sonm"),
    ("sortShow", *b"sosn"),
    ("grouping", *b"\xa9grp"),
    ("episodeID", *b"tven"),
    ("account", *b"apID"),
    ("purchaseDate", *b"purd"),
    ("copyright", *b"cprt"),
    ("encodedBy", *b"\xa9enc"),
    ("encodingTool", *b"\xa9too"),
    ("xid", *b"xid "),
    ("tags", *b"keyw"),
];
fn tag_read(p: &Path) -> Result<Tag, String> {
    std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        Tag::read_with_path(
            p,
            &ReadConfig {
                read_audio_info: false,
                ..ReadConfig::DEFAULT
            },
        )
    }))
    .map_err(|_| "MP4 metadata: malformed movie header (mvhd)".to_string())?
    .map_err(|e| format!("MP4 metadata: {e}"))
}
fn free(key: &str) -> DataIdent {
    FreeformIdent::new_borrowed("com.apple.iTunes", key).into()
}
pub fn read_metadata(p: &Path) -> Result<BTreeMap<String, String>, String> {
    let tag = tag_read(p)?;
    let mut result = BTreeMap::new();
    for (key, atom) in TEXT_FIELDS {
        if let Some(s) = tag.strings_of(&Fourcc(*atom)).next() {
            result.insert((*key).into(), s.into());
        }
    }
    for key in [
        "genreType",
        "seasonDescription",
        "studio",
        "dvdSeason",
        "dvdEpisode",
        "absoluteEpisode",
        "useDVDOrder",
        "rating",
        "albumRating",
        "creationDate",
    ] {
        if let Some(s) = tag.strings_of(&free(key)).next() {
            result.insert(key.into(), s.into());
        }
    }
    for (key, atom) in [
        ("contentID", *b"cnID"),
        ("artistID", *b"atID"),
        ("composerID", *b"cmID"),
        ("country", *b"sfID"),
        ("playlistID", *b"plID"),
        ("genreID", *b"geID"),
        ("advisory", *b"rtng"),
        ("definition", *b"hdvd"),
    ] {
        if let Some(bytes) = tag.data_of(&Fourcc(atom)).next().and_then(Data::bytes) {
            if bytes.len() <= 8 {
                result.insert(
                    key.into(),
                    bytes
                        .iter()
                        .fold(0u64, |n, b| (n << 8) | u64::from(*b))
                        .to_string(),
                );
            }
        }
    }
    for (key, atom) in [("track", *b"trkn"), ("disc", *b"disk")] {
        if let Some(b) = tag.data_of(&Fourcc(atom)).next().and_then(Data::bytes) {
            if b.len() >= 6 {
                let n = u16::from_be_bytes([b[2], b[3]]);
                let count = u16::from_be_bytes([b[4], b[5]]);
                if n > 0 {
                    result.insert(format!("{key}Number"), n.to_string());
                }
                if count > 0 {
                    result.insert(format!("{key}Count"), count.to_string());
                }
            }
        }
    }
    if let Some(s) = tag.strings_of(&free("iTunEXTC")).next() {
        if let Some(r) = s.split('|').nth(1) {
            result.insert("contentRating".into(), r.into());
        }
    }
    if let Some(s) = tag.strings_of(&free("iTunMOVI")).next() {
        let value = plist::Value::from_reader_xml(s.as_bytes())
            .map_err(|e| format!("Existing Apple credits could not be read: {e}"))?;
        if let Some(dict) = value.as_dictionary() {
            for (key, source) in [
                ("actors", "cast"),
                ("directors", "directors"),
                ("coDirectors", "codirectors"),
                ("producers", "producers"),
                ("screenwriters", "screenwriters"),
            ] {
                if let Some(array) = dict.get(source).and_then(plist::Value::as_array) {
                    let joined = array
                        .iter()
                        .filter_map(|v| v.as_dictionary()?.get("name")?.as_string())
                        .collect::<Vec<_>>()
                        .join("\n");
                    if !joined.is_empty() {
                        result.insert(key.into(), joined);
                    }
                }
            }
            if let Some(studio) = dict
                .get("studio")
                .and_then(plist::Value::as_string)
                .filter(|s| !s.is_empty())
            {
                result.insert("studio".into(), studio.into());
            }
        }
    }
    Ok(result)
}
pub fn write_metadata(job: &Job, p: &Path) -> Result<(), String> {
    let mut tag = tag_read(p)?;
    // Remuxers need not know every existing Apple tag. Copy the original item list first.
    let source = tag_read(&job.current_path)?;
    let mut data = mp4ameta::Userdata::default();
    for (id, value) in source.userdata.data() {
        data.add_data(id.clone(), value.clone());
    }
    let mut values = job.direct.metadata.clone();
    let i = &job.identity;
    values.insert(
        "name".into(),
        if i.kind == "tv" {
            i.episode_title.clone()
        } else {
            i.title.clone()
        },
    );
    values.insert(
        "show".into(),
        if i.kind == "tv" {
            i.title.clone()
        } else {
            String::new()
        },
    );
    if !job.direct.overrides.contains("releaseDate")
        && values.get("releaseDate").is_none_or(|s| s.is_empty())
    {
        values.insert(
            "releaseDate".into(),
            i.release_date
                .clone()
                .unwrap_or_else(|| i.year.map(|n| n.to_string()).unwrap_or_default()),
        );
    }
    if !job.direct.overrides.contains("episodeID") {
        values.insert(
            "episodeID".into(),
            if i.kind == "tv" {
                format!(
                    "S{:02}E{:02}",
                    i.season.unwrap_or(0),
                    i.episode.unwrap_or(0)
                )
            } else {
                String::new()
            },
        );
    }
    for (key, atom) in TEXT_FIELDS {
        if let Some(v) = values.get(*key) {
            data.remove_data_of(&Fourcc(*atom));
            if !v.is_empty() {
                data.set_data(Fourcc(*atom), Data::Utf8(v.clone()));
            }
        }
    }
    for (key, atom, width) in [
        ("contentID", *b"cnID", 4),
        ("artistID", *b"atID", 4),
        ("composerID", *b"cmID", 4),
        ("country", *b"sfID", 4),
        ("playlistID", *b"plID", 8),
        ("genreID", *b"geID", 4),
        ("advisory", *b"rtng", 1),
        ("definition", *b"hdvd", 1),
    ] {
        if let Some(v) = values.get(key) {
            data.remove_data_of(&Fourcc(atom));
            if !v.is_empty() {
                let n = v
                    .parse::<u64>()
                    .map_err(|_| format!("{key} must be a nonnegative integer"))?;
                if width < 8 && n >= (1u64 << (width * 8)) {
                    return Err(format!("{key} is out of range"));
                }
                data.set_data(
                    Fourcc(atom),
                    Data::BeSigned(n.to_be_bytes()[8 - width..].to_vec()),
                );
            }
        }
    }
    for (atom, n) in [
        (*b"stik", Some(if i.kind == "tv" { 10u32 } else { 9 })),
        (*b"tvsn", if i.kind == "tv" { i.season } else { None }),
        (*b"tves", if i.kind == "tv" { i.episode } else { None }),
    ] {
        data.remove_data_of(&Fourcc(atom));
        if let Some(n) = n {
            data.set_data(
                Fourcc(atom),
                Data::BeSigned(if atom == *b"stik" {
                    vec![n as u8]
                } else {
                    n.to_be_bytes().to_vec()
                }),
            );
        }
    }
    for (key, atom) in [("track", *b"trkn"), ("disc", *b"disk")] {
        let num_key = format!("{key}Number");
        let count_key = format!("{key}Count");
        if values.contains_key(&num_key) || values.contains_key(&count_key) {
            let (existing_n, existing_count) = data
                .data_of(&Fourcc(atom))
                .next()
                .and_then(Data::bytes)
                .filter(|b| b.len() >= 6)
                .map(|b| (u16::from_be_bytes([b[2], b[3]]), u16::from_be_bytes([b[4], b[5]])))
                .unwrap_or((0, 0));
            let n = match values.get(&num_key) {
                Some(s) if s.is_empty() => 0,
                Some(s) => s.parse::<u16>().map_err(|_| format!("Invalid {key} number"))?,
                None => existing_n,
            };
            let count = match values.get(&count_key) {
                Some(s) if s.is_empty() => 0,
                Some(s) => s.parse::<u16>().map_err(|_| format!("Invalid {key} count"))?,
                None => existing_count,
            };
            data.remove_data_of(&Fourcc(atom));
            if n > 0 || count > 0 {
                let mut b = vec![0, 0];
                b.extend(n.to_be_bytes());
                b.extend(count.to_be_bytes());
                b.extend([0, 0]);
                data.set_data(Fourcc(atom), Data::Reserved(b));
            }
        }
    }
    for key in [
        "genreType",
        "seasonDescription",
        "studio",
        "dvdSeason",
        "dvdEpisode",
        "absoluteEpisode",
        "useDVDOrder",
        "rating",
        "albumRating",
        "creationDate",
    ] {
        if let Some(v) = values.get(key) {
            data.remove_data_of(&free(key));
            if !v.is_empty() {
                data.set_data(free(key), Data::Utf8(v.clone()));
            }
        }
    }
    if let Some(rating) = values.get("contentRating") {
        data.remove_data_of(&free("iTunEXTC"));
        if !rating.is_empty() {
            data.set_data(
                free("iTunEXTC"),
                Data::Utf8(format!(
                    "{}|{rating}|0|",
                    if i.kind == "tv" { "us-tv" } else { "mpaa" }
                )),
            );
        }
    }
    if [
        "actors",
        "directors",
        "coDirectors",
        "producers",
        "screenwriters",
        "studio",
    ]
    .iter()
    .any(|k| values.contains_key(*k))
    {
        let mut dictionary = data
            .strings_of(&free("iTunMOVI"))
            .next()
            .and_then(|s| plist::Value::from_reader_xml(s.as_bytes()).ok())
            .and_then(|v| v.into_dictionary())
            .unwrap_or_default();
        for (key, target) in [
            ("actors", "cast"),
            ("directors", "directors"),
            ("coDirectors", "codirectors"),
            ("producers", "producers"),
            ("screenwriters", "screenwriters"),
        ] {
            if let Some(names) = values.get(key) {
                let array: Vec<_> = names
                    .lines()
                    .filter(|s| !s.trim().is_empty())
                    .map(|name| {
                        let mut person = plist::Dictionary::new();
                        person.insert("name".into(), plist::Value::String(name.trim().into()));
                        plist::Value::Dictionary(person)
                    })
                    .collect();
                if array.is_empty() {
                    dictionary.remove(target);
                } else {
                    dictionary.insert(target.into(), plist::Value::Array(array));
                }
            }
        }
        if let Some(studio) = values.get("studio") {
            if studio.is_empty() {
                dictionary.remove("studio");
            } else {
                dictionary.insert("studio".into(), plist::Value::String(studio.clone()));
            }
        }
        data.remove_data_of(&free("iTunMOVI"));
        if !dictionary.is_empty() {
            let mut xml = Vec::new();
            plist::Value::Dictionary(dictionary)
                .to_writer_xml(&mut xml)
                .map_err(|e| e.to_string())?;
            data.set_data(
                free("iTunMOVI"),
                Data::Utf8(String::from_utf8(xml).map_err(|e| e.to_string())?),
            );
        }
    }
    if i.kind == "tv" {
        data.remove_artworks()
    } else if !job.direct.artwork_path.is_empty() {
        if let Some(expected) = &job.direct.artwork_fingerprint {
            if Fingerprint::read(Path::new(&job.direct.artwork_path))? != *expected {
                return Err("Selected poster changed since approval".into());
            }
        }
        let bytes = fs::read(&job.direct.artwork_path).map_err(|e| e.to_string())?;
        if bytes.len() > 16 * 1024 * 1024 {
            return Err("Poster exceeds 16 MiB".into());
        }
        let format = if bytes.starts_with(b"\x89PNG\r\n\x1a\n") {
            mp4ameta::ImgFmt::Png
        } else if bytes.starts_with(&[0xff, 0xd8, 0xff]) {
            mp4ameta::ImgFmt::Jpeg
        } else {
            return Err("Choose a JPEG or PNG poster".into());
        };
        data.set_artwork(mp4ameta::Img {
            fmt: format,
            data: bytes,
        });
    }
    tag.userdata = data;
    tag.write_with_path(
        p,
        &WriteConfig {
            write_meta_items: true,
            ..WriteConfig::NONE
        },
    )
    .map_err(|e| e.to_string())?;
    let actual = tag_read(p)?;
    if actual.userdata.data().collect::<Vec<_>>() != tag.userdata.data().collect::<Vec<_>>() {
        return Err("MP4 tag readback did not match the approved metadata".into());
    }
    fs::File::open(p)
        .and_then(|f| f.sync_all())
        .map_err(|e| e.to_string())?;
    Ok(())
}
pub fn fast_start(p: &Path) -> Result<bool, String> {
    let mut f = fs::File::open(p).map_err(|e| e.to_string())?;
    let len = f.metadata().map_err(|e| e.to_string())?.len();
    let mut pos = 0;
    let mut moov = false;
    while pos + 8 <= len {
        let mut b = [0u8; 8];
        f.read_exact(&mut b).map_err(|e| e.to_string())?;
        let mut size = u32::from_be_bytes(b[..4].try_into().unwrap()) as u64;
        let mut header = 8;
        if size == 1 {
            let mut large = [0u8; 8];
            f.read_exact(&mut large).map_err(|e| e.to_string())?;
            size = u64::from_be_bytes(large);
            header = 16;
        }
        if size == 0 {
            size = len - pos
        }
        if size < header || size > len - pos {
            return Err("Malformed MP4 atom size".into());
        }
        if &b[4..] == b"moov" {
            moov = true
        }
        if &b[4..] == b"mdat" {
            return Ok(moov);
        }
        pos += size;
        f.seek(SeekFrom::Start(pos)).map_err(|e| e.to_string())?;
    }
    Err("No MP4 media data".into())
}
impl Core {
    pub(crate) fn direct_command(&mut self, v: Value) -> Result<Value, String> {
        let command = v["command"].as_str().unwrap_or("");
        if command == "direct_add" {
            let raw = v["path"].as_str().ok_or("Select a video")?;
            ensure_not_symlink(Path::new(raw))?;
            let path = fs::canonicalize(raw).map_err(|e| e.to_string())?;
            let fp = Fingerprint::read(&path)?;
            if self.jobs()?.iter().any(|j| j.fingerprint.same_object(&fp)) {
                return self.snapshot();
            }
            if !video(&path) {
                return Err("Choose a video file".into());
            }
            let id = identifier();
            let job:Job=serde_json::from_value(json!({"id":id,"original_path":path,"current_path":path,"fingerprint":fp,"identity":parse_identity(path.file_stem().and_then(|s|s.to_str()).unwrap_or("")),"subtitles":companions(&path)?,"included":true,"revision":1,"state":"needs_review","message":"","created_ms":now(),"updated_ms":now(),"prepared_path":null,"batch_id":null,"approved_revision":null,"iflicks_id":null,"process_identity":null,"progress":null,"iflicks_status":null,"output_path":null,"output_fingerprint":null,"output_attested_ms":null})).map_err(|e|e.to_string())?;
            self.save(&job)?;
            return self.snapshot();
        }
        if command == "direct_naming" {
            if let Some(value) = v.get("settings") {
                let settings: Naming =
                    serde_json::from_value(value.clone()).map_err(|e| e.to_string())?;
                self.db.put("direct:naming", &settings)?;
            }
            return Ok(self
                .db
                .get("direct:naming")?
                .unwrap_or(json!(Naming::default())));
        }
        if command == "direct_preview" {
            let naming: Naming = serde_json::from_value(
                self.db
                    .get("direct:naming")?
                    .unwrap_or(json!(Naming::default())),
            )
            .map_err(|e| e.to_string())?;
            let mut jobs = vec![];
            let mut actions = vec![];
            let mut errors = vec![];
            let mut seen = BTreeSet::new();
            for id in v["ids"].as_array().ok_or("Choose videos")? {
                let job = self.job(id.as_str().ok_or("Invalid ID")?)?;
                let check = (|| {
                    if !job.editable() || !job.included {
                        return Err("Select included editable jobs".into());
                    }
                    self.validate_source(&job)?;
                    let name = filename(&job, &naming)?;
                    let dest = if job.direct.destination.is_empty() {
                        self.config()?.output_folder
                    } else {
                        ensure_not_symlink(Path::new(&job.direct.destination))?;
                        fs::canonicalize(&job.direct.destination).map_err(|e| e.to_string())?
                    };
                    if !dest.is_dir() {
                        return Err("Choose a destination folder".into());
                    }
                    let target = dest.join(name);
                    self.check_target(&job.current_path, &target, &mut seen)?;
                    if target == job.current_path {
                        return Err("Output must be separate from the source".into());
                    }
                    let mut subs = vec![];
                    let mut langs = BTreeSet::new();
                    for sub in job.subtitles.iter().filter(|s| s.selected) {
                        if !langs.insert(&sub.language) {
                            return Err("Choose one subtitle per language/variant".into());
                        }
                        let target_sub = target.with_extension(format!("{}.srt", sub.language));
                        self.check_target(&sub.current_path, &target_sub, &mut seen)?;
                        subs.push(json!({"source":sub.current_path,"target":target_sub,"language":sub.language}));
                    }
                    actions.push(json!({"id":job.id,"source":job.current_path,"target":target,"identity":job.identity,"subtitles":subs,"streaming":job.direct.streaming,"trash_source":job.direct.trash_source,"tracks":job.direct.tracks,"artwork":if job.identity.kind=="tv"{"Remove embedded cover artwork"}else{"Embed selected poster / preserve existing"}}));
                    Ok::<(), String>(())
                })();
                if let Err(e) = check {
                    errors.push(format!("{}: {e}", job.current_path.display()))
                }
                jobs.push(job);
            }
            if jobs.is_empty() {
                return Err("Choose at least one video".into());
            }
            let token = identifier();
            let preview = json!({"token":token,"jobs":jobs,"actions":actions,"errors":errors,"config":self.config()?,"naming":naming});
            self.db.put(&format!("direct:preview:{token}"), &preview)?;
            return Ok(preview);
        }
        if command == "direct_approve" {
            let token = v["token"].as_str().ok_or("Missing preview")?;
            let preview = self
                .db
                .get(&format!("direct:preview:{token}"))?
                .ok_or("Expired preview")?;
            if preview["errors"].as_array().is_none_or(|e| !e.is_empty()) {
                return Err("Resolve preview errors".into());
            }
            if preview["config"] != json!(self.config()?)
                || preview["naming"]
                    != self
                        .db
                        .get("direct:naming")?
                        .unwrap_or(json!(Naming::default()))
            {
                return Err("Settings changed; preview again".into());
            }
            let jobs: Vec<Job> =
                serde_json::from_value(preview["jobs"].clone()).map_err(|e| e.to_string())?;
            let mut seen = BTreeSet::new();
            for j in &jobs {
                if json!(self.job(&j.id)?) != json!(j) {
                    return Err("Review changed; preview again".into());
                }
                self.validate_source(j)?;
                let action = preview["actions"]
                    .as_array()
                    .and_then(|a| a.iter().find(|item| item["id"] == j.id))
                    .ok_or("Missing preview action")?;
                let target = PathBuf::from(action["target"].as_str().ok_or("Missing target")?);
                self.check_target(&j.current_path, &target, &mut seen)?;
                for sub in j.subtitles.iter().filter(|s| s.selected) {
                    let target_sub = target.with_extension(format!("{}.srt", sub.language));
                    self.check_target(&sub.current_path, &target_sub, &mut seen)?;
                }
            }
            self.db.transaction(||{for mut j in jobs {j.direct.backend=true;
 if !j.direct.overrides.contains("comment") && j.direct.metadata.get("comment").is_none_or(|s|s.is_empty()||s.starts_with("Information courtesy of")) {if let Some(video)=j.direct.inspection["rule_media"].as_array().and_then(|a|a.first()){let codec=if video["format"]=="HEVC"{"HEVC"}else{"H.264"};let key=format!("{} {codec}",job_quality(&j));if let Some(comment)=preview["naming"]["suffixes"][&key].as_str(){j.direct.metadata.insert("comment".into(),comment.into());}}}
 j.direct.target=Some(PathBuf::from(preview["actions"].as_array().unwrap().iter().find(|a|a["id"]==j.id).unwrap()["target"].as_str().unwrap()));j.state="direct_queued".into();j.approved_revision=Some(j.revision);self.save(&j)?;self.log("direct_approved",Some(&j),"Approved completed downloads, metadata, tracks, names and source Trash policy")?;}Ok(())})?;
            return self.snapshot();
        }
        let mut j = self.job(v["id"].as_str().ok_or("Missing job ID")?)?;
        match command {
            "direct_readback" => {
                let p = j
                    .output_path
                    .as_ref()
                    .or(j.direct.temporary.as_ref())
                    .unwrap_or(&j.current_path);
                Ok(json!(read_metadata(p)?))
            }
            "direct_inspect" => {
                if !j.editable() {
                    return Err("Inspect editable jobs only".into());
                }
                if v["revision"].as_u64() != Some(j.revision) {
                    return Err("Stale inspection".into());
                }
                let source_tag = tag_read(&j.current_path)?;
                if j.direct.artwork_path.is_empty() && !j.direct.overrides.contains("artwork") {
                    if let Some(image) = source_tag.artwork() {
                        if image.data.len() > 16 * 1024 * 1024 {
                            return Err("Existing artwork exceeds the 16 MiB limit".into());
                        }
                        let folder = self.home.join("artwork");
                        fs::create_dir_all(&folder).map_err(|e| e.to_string())?;
                        let path = folder.join(format!("{}-original-{}.img", j.id, identifier()));
                        publish(image.data, &path)?;
                        j.direct.artwork_fingerprint = Some(Fingerprint::read(&path)?);
                        j.direct.artwork_path = path.to_string_lossy().into();
                    }
                }
                let fields = read_metadata(&j.current_path)?;
                for (k, val) in fields {
                    if !j.direct.overrides.contains(&k) {
                        j.direct.metadata.entry(k).or_insert(val);
                    }
                }
                if j.direct.inspection.is_null() {
                    if !j.direct.overrides.contains("streaming") {
                        if let Some(streaming) = v["default_streaming"].as_bool() {
                            j.direct.streaming = streaming;
                        }
                    }
                    if !j.direct.overrides.contains("trash_source") {
                        if let Some(trash) = v["default_trash"].as_bool() {
                            j.direct.trash_source = trash;
                        }
                    }
                }
                j.direct.inspection = v["inspection"].clone();
                if let Some(video) = j.direct.inspection["rule_media"]
                    .as_array()
                    .and_then(|a| a.first())
                {
                    let height = video["height"].as_u64().unwrap_or(0);
                    if !j.direct.overrides.contains("definition") {
                        j.direct.metadata.insert(
                            "definition".into(),
                            (if height > 1080 {
                                3
                            } else if height > 720 {
                                2
                            } else if height > 560 {
                                1
                            } else {
                                0
                            })
                            .to_string(),
                        );
                    }
                }
                j.revision += 1;
                self.save(&j)?;
                Ok(json!(j))
            }
            "direct_begin" => {
                if j.state != "direct_queued" || j.approved_revision != Some(j.revision) {
                    return Err("No approved direct job".into());
                }
                self.validate_source(&j)?;
                let target = j.direct.target.clone().ok_or("No output intent")?;
                if target.exists() {
                    return Err("Output already exists".into());
                }
                self.retain(&mut j)?;
                let tmp = target.with_file_name(format!(".relay-{}-{}.mp4", j.id, identifier()));
                fs::OpenOptions::new()
                    .write(true)
                    .create_new(true)
                    .open(&tmp)
                    .map_err(|e| e.to_string())?;
                let outcome = (|| {
                    j.direct.temporary_identity = Some(Fingerprint::read(&tmp)?);
                    j.direct.temporary = Some(tmp.clone());
                    j.state = "direct_processing".into();
                    self.save(&j)?;
                    self.log(
                        "direct_processing",
                        Some(&j),
                        "Owned output staging created; source unchanged",
                    )?;
                    Ok(json!(j))
                })();
                if outcome.is_err() {
                    let _ = fs::remove_file(&tmp);
                }
                outcome
            }
            "direct_tag" => {
                self.validate_source(&j)?;
                let p = self.owned_temporary(&j)?;
                write_metadata(&j, &p)?;
                if j.direct.streaming && !fast_start(&p)? {
                    return Err("Final MP4 is not optimized for streaming".into());
                }
                j.direct.receipt = Some(Fingerprint::read(&p)?);
                j.message = "Metadata readback verified; awaiting stream validation".into();
                self.save(&j)?;
                Ok(json!(j))
            }
            "direct_publish" => {
                self.validate_source(&j)?;
                let p = self.owned_temporary(&j)?;
                let expected = j
                    .direct
                    .receipt
                    .clone()
                    .ok_or("No tag verification receipt")?;
                if Fingerprint::read(&p)? != expected {
                    return Err("Staged output changed after verification".into());
                }
                j.state = "direct_publishing".into();
                self.save(&j)?;
                let target = j.direct.target.clone().ok_or("No target")?;
                rename_exclusive(&p, &target)?;
                j.direct.temporary = None;
                j.direct.temporary_identity = None;
                j.output_path = Some(target);
                j.output_fingerprint = Some(expected);
                j.output_attested_ms = Some(now());
                j.state = "output_verified".into();
                j.message = "Direct output verified and published".into();
                self.save(&j)?;
                self.log(
                    "direct_published",
                    Some(&j),
                    v["evidence"].as_str().unwrap_or("Stream verification"),
                )?;
                if let Err(e) = self.reconcile(&mut j) {
                    j.state = "reconciliation_failed".into();
                    j.message = e.clone();
                    self.save(&j)?;
                    return Err(e);
                }
                Ok(json!(j))
            }
            "direct_error" => {
                if j.output_path.is_none() {
                    j.state = "direct_failed".into()
                } else if j.state == "output_verified" {
                    j.state = "reconciliation_failed".into()
                }
                j.message = v["message"].as_str().unwrap_or("Processing failed").into();
                self.save(&j)?;
                self.log("direct_error", Some(&j), &j.message)?;
                self.snapshot()
            }
            "direct_retry" => {
                if !["direct_failed", "direct_interrupted", "direct_queued"]
                    .contains(&j.state.as_str())
                    || j.output_path.is_some()
                {
                    return Err("Output exists; retry subtitles/cleanup separately".into());
                }
                if let Ok(p) = self.owned_temporary(&j) {
                    fs::remove_file(p).map_err(|e| e.to_string())?;
                }
                j.direct.temporary = None;
                j.direct.temporary_identity = None;
                j.direct.receipt = None;
                j.state = "needs_review".into();
                j.approved_revision = None;
                j.revision += 1;
                self.save(&j)?;
                self.snapshot()
            }
            "direct_cleanup_check" => {
                if !j.direct.backend
                    || !j.direct.trash_source
                    || j.state != "complete"
                    || j.direct.trash_path.is_some()
                {
                    return Err("No completed source awaiting Trash".into());
                }
                self.validate_source(&j)?;
                if Fingerprint::read(j.output_path.as_ref().ok_or("Missing output")?)?
                    != *j.output_fingerprint.as_ref().ok_or("Missing receipt")?
                {
                    return Err("Output changed; source retained".into());
                }
                self.db.put(
                    &format!("direct:trash:{}", j.id),
                    &json!({"source":j.current_path,"fingerprint":j.fingerprint,"intent_ms":now()}),
                )?;
                Ok(json!(j))
            }
            "direct_cleanup_done" => {
                if self.db.get(&format!("direct:trash:{}", j.id))?.is_none() {
                    return Err("No cleanup intent".into());
                }
                j.direct.trash_path = Some(v["path"].as_str().ok_or("No Trash path")?.into());
                self.save(&j)?;
                self.log(
                    "source_trashed",
                    Some(&j),
                    "Verified unchanged input moved to recoverable macOS Trash",
                )?;
                self.snapshot()
            }
            _ => Err("Unknown direct command".into()),
        }
    }
    fn owned_temporary(&self, j: &Job) -> Result<PathBuf, String> {
        if !j.direct.backend
            || ![
                "direct_processing",
                "direct_publishing",
                "direct_interrupted",
                "direct_failed",
            ]
            .contains(&j.state.as_str())
        {
            return Err("No owned processing job".into());
        }
        let p = j.direct.temporary.clone().ok_or("No owned staging file")?;
        if !Fingerprint::read(&p)?.same_object(
            j.direct
                .temporary_identity
                .as_ref()
                .ok_or("Missing staging identity")?,
        ) {
            return Err("Staging file was replaced; refusing to touch it".into());
        }
        Ok(p)
    }
    pub(crate) fn recover_direct(&self, mut j: Job) -> Result<(), String> {
        if j.state == "direct_publishing" {
            if let (Some(p), Some(fp)) = (&j.direct.target, &j.direct.receipt) {
                if Fingerprint::read(p).ok().as_ref() == Some(fp) {
                    j.output_path = Some(p.clone());
                    j.output_fingerprint = Some(fp.clone());
                    j.state = "output_verified".into();
                    j.message = "Recovered published output; retry subtitle publication".into();
                    return self.save(&j);
                }
            }
        }
        if ["direct_processing", "direct_publishing", "direct_queued"].contains(&j.state.as_str()) {
            j.state = "direct_interrupted".into();
            j.message = "Interrupted direct job; source retained. Review before retrying.".into();
            self.save(&j)?
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn rule_thresholds_match_exported_iflicks_rules() {
        for (height, expected) in [
            (358, "SD"),
            (560, "SD"),
            (561, "HD 720p"),
            (720, "HD 720p"),
            (721, "HD 1080p"),
            (1080, "HD 1080p"),
            (1081, "4K"),
            (2160, "4K"),
        ] {
            assert_eq!(quality(height), expected);
        }
    }
    #[test]
    fn filenames_and_explicit_clears() {
        let mut job:Job=serde_json::from_value(json!({"id":"fixture","original_path":"/input.mp4","current_path":"/input.mp4","fingerprint":{"device":1,"inode":1,"size":1,"modified_ns":"0"},"identity":{"kind":"tv","title":"Show","season":0,"episode":3,"episode_title":"A / special: episode"},"subtitles":[],"included":true,"revision":1,"state":"needs_review","message":"","created_ms":0,"updated_ms":0})).unwrap();
        job.direct.inspection = json!({"rule_media":[{"height":1080,"format":"AVC"}]});
        let naming = Naming::default();
        assert_eq!(
            filename(&job, &naming).unwrap(),
            "Show – s00e03 – A special episode-HD 1080p H.264 DL.mp4"
        );
        job.direct.metadata.insert("comment".into(), "".into());
        job.direct.overrides.insert("comment".into());
        assert!(filename(&job, &naming).unwrap().ends_with("episode-.mp4"));
        job.direct.filename = "../escape.mp4".into();
        assert!(filename(&job, &naming).is_err());
        job.direct.filename = "Manual name.mp4".into();
        assert_eq!(filename(&job, &naming).unwrap(), "Manual name.mp4");
        job.direct.filename.clear();
        job.identity.year = Some(2019);
        job.identity.include_year = true;
        assert_eq!(
            filename(&job, &naming).unwrap(),
            "Show (2019) – s00e03 – A special episode-.mp4"
        );
    }
}
