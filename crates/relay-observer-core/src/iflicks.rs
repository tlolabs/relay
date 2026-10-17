use serde::{Deserialize, Serialize};

#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum EventKind {
    IflicksAppStarted,
    IflicksAppExited,
    IflicksSnapshot,
    IflicksQueueRemoved,
    IflicksQueryError,
    IflicksSamplingGap,
    IflicksCaptureState,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Process {
    pub pid: i32,
    pub launch_unix_ms: Option<u64>,
    pub bundle_identifier: String,
    pub version: Option<String>,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Video {
    pub id: String,
    pub status: String,
    pub status_code: String,
    pub progress: Option<i64>,
    pub file_path: Option<String>,
    pub file_error: Option<String>,
}

/// Whitelisted diagnostic payload. Callers cannot inject filesystem events or
/// override the writer-owned sequence and capture timestamps.
#[derive(Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Observation {
    pub event: EventKind,
    pub observed_unix_ms: u64,
    pub process: Option<Process>,
    pub sample_started_unix_ms: Option<u64>,
    pub sample_finished_unix_ms: Option<u64>,
    pub last_successful_sample_unix_ms: Option<u64>,
    pub videos: Option<Vec<Video>>,
    pub removed_video_ids: Option<Vec<String>>,
    pub error_code: Option<i32>,
    pub message: Option<String>,
    pub missed_intervals: Option<u64>,
    pub duration_ms: Option<u64>,
    pub reason: Option<String>,
    pub state: Option<String>,
}

impl Observation {
    pub fn validate(&self) -> Result<(), String> {
        if let Some(process) = &self.process
            && (process.pid <= 0 || process.bundle_identifier != "com.iflicksapp.iFlicks3")
        {
            return Err("Invalid iFlicks process identity".into());
        }
        if let Some(videos) = &self.videos {
            let mut ids = std::collections::BTreeSet::new();
            for video in videos {
                if video.id.is_empty() || !ids.insert(&video.id) {
                    return Err("Missing or duplicate iFlicks video ID".into());
                }
            }
        }
        let sample = self.process.is_some()
            && self.sample_started_unix_ms.is_some()
            && self.sample_finished_unix_ms >= self.sample_started_unix_ms;
        let valid = match self.event {
            EventKind::IflicksAppStarted | EventKind::IflicksAppExited => self.process.is_some(),
            EventKind::IflicksSnapshot => sample && self.videos.is_some(),
            EventKind::IflicksQueueRemoved => sample && self.removed_video_ids.is_some(),
            EventKind::IflicksQueryError => {
                sample && self.error_code.is_some() && self.message.is_some()
            }
            EventKind::IflicksSamplingGap => self.duration_ms.is_some() && self.message.is_some(),
            EventKind::IflicksCaptureState => self.state.is_some(),
        };
        if valid {
            Ok(())
        } else {
            Err("Incomplete iFlicks diagnostic payload".into())
        }
    }
}
