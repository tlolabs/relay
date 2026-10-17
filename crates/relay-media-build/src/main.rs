//! Explicit Rust-owned native dependency build. Never runs during ordinary cargo test.
use std::{
    env, fs,
    path::{Path, PathBuf},
    process::Command,
};
fn run(dir: &Path, program: &str, args: &[&str]) {
    let status = Command::new(program)
        .args(args)
        .current_dir(dir)
        .env("MACOSX_DEPLOYMENT_TARGET", "14.0")
        .env("CFLAGS", "-arch x86_64 -mmacosx-version-min=14.0 -O2")
        .env("CXXFLAGS", "-arch x86_64 -mmacosx-version-min=14.0 -O2")
        .status()
        .unwrap_or_else(|e| panic!("{program}: {e}"));
    assert!(status.success(), "{program} failed in {}", dir.display());
}
unsafe extern "C" {
    fn flock(fd: i32, operation: i32) -> i32;
}
fn main() {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .unwrap()
        .parent()
        .unwrap()
        .to_owned();
    fs::create_dir_all(root.join("build/media")).unwrap();
    let lock_file = fs::OpenOptions::new()
        .create(true)
        .truncate(false)
        .read(true)
        .write(true)
        .open(root.join("build/media/build.lock"))
        .unwrap();
    use std::os::fd::AsRawFd;
    assert_eq!(
        unsafe { flock(lock_file.as_raw_fd(), 2) },
        0,
        "Cannot lock native dependency build"
    );
    let manifest = root.join("media-dependencies.json");
    let text = fs::read_to_string(&manifest).expect("dependency manifest");
    let inputs = serde_json::json!({"manifest":text,"builder":include_str!("main.rs"),"compiler":String::from_utf8_lossy(&Command::new("clang").arg("--version").output().unwrap().stdout).to_string()}).to_string();
    let lock: serde_json::Value = serde_json::from_str(&text).unwrap();
    let base = root.join("build/media");
    let downloads = base.join("downloads");
    let prefix = base.join("install");
    fs::create_dir_all(&downloads).unwrap();
    let receipt = base.join("build-receipt.json");
    if fs::read_to_string(&receipt).ok().as_deref() == Some(inputs.as_str())
        && ["ffmpeg", "ffprobe", "mediainfo"]
            .iter()
            .all(|x| prefix.join("bin").join(x).is_file())
    {
        println!(
            "Native media dependencies are current: {}",
            prefix.display()
        );
        return;
    }
    let jobs = env::var("RELAY_BUILD_JOBS").unwrap_or_else(|_| "4".into());
    for dep in lock["sources"].as_array().unwrap() {
        let name = dep["archive"].as_str().unwrap();
        let archive = downloads.join(name);
        if !archive.is_file() {
            run(
                &downloads,
                "curl",
                &[
                    "--fail",
                    "--location",
                    "--proto",
                    "=https",
                    "--tlsv1.2",
                    dep["url"].as_str().unwrap(),
                    "-o",
                    name,
                ],
            );
        }
        let output = Command::new("shasum")
            .args(["-a", "256"])
            .arg(&archive)
            .output()
            .unwrap();
        let hash = String::from_utf8_lossy(&output.stdout);
        assert!(
            output.status.success() && hash.split_whitespace().next() == dep["sha256"].as_str(),
            "Source checksum mismatch: {name}"
        );
        let source = base.join(dep["directory"].as_str().unwrap());
        // Re-extract only this manifest-owned source tree on a dependency update.
        if source.exists() {
            fs::remove_dir_all(&source).unwrap();
        }
        run(&base, "tar", &["-xf", archive.to_str().unwrap()]);
        if dep["name"] == "ffmpeg" {
            let install = format!("--prefix={}", prefix.display());
            run(
                &source,
                "./configure",
                &[
                    &install,
                    "--arch=x86_64",
                    "--cc=clang",
                    "--disable-x86asm",
                    "--disable-debug",
                    "--disable-doc",
                    "--disable-ffplay",
                    "--disable-shared",
                    "--enable-static",
                    "--disable-autodetect",
                    "--disable-network",
                    "--enable-avdevice",
                    "--enable-indev=lavfi",
                    "--enable-videotoolbox",
                    "--disable-everything",
                    "--enable-indev=lavfi",
                    "--enable-ffmpeg",
                    "--enable-ffprobe",
                    "--enable-protocol=file,pipe",
                    "--enable-demuxer=mov,matroska,srt,ffmetadata",
                    "--enable-muxer=mp4,mov,hash,streamhash,null",
                    "--enable-parser=h264,hevc,aac,ac3",
                    "--enable-decoder=h264,hevc,aac,ac3,eac3,movtext,subrip,rawvideo,pcm_s16le,pcm_f64le",
                    "--enable-encoder=movtext,aac,h264_videotoolbox",
                    "--enable-filter=color,sine,aformat,aresample,format,scale,null,anull",
                    "--enable-bsf=h264_mp4toannexb,hevc_mp4toannexb,aac_adtstoasc,extract_extradata",
                    "--extra-cflags=-mmacosx-version-min=14.0",
                ],
            );
            run(&source, "make", &["-j", &jobs]);
            run(&source, "make", &["install"]);
        } else {
            let install = format!("--prefix={}", prefix.display());
            // Official all-in-one release includes generated configure scripts and ZenLib.
            for (sub, extra) in [
                ("ZenLib/Project/GNU/Library", vec![]),
                (
                    "MediaInfoLib/Project/GNU/Library",
                    vec!["--without-libcurl"],
                ),
                ("MediaInfo/Project/GNU/CLI", vec!["--enable-staticlibs"]),
            ] {
                let dir = source.join(sub);
                let mut args = vec![install.as_str(), "--disable-shared", "--enable-static"];
                args.extend(extra);
                run(&dir, "./configure", &args);
                run(&dir, "make", &["-j", &jobs]);
                run(&dir, "make", &["install"]);
            }
        }
    }
    fs::write(receipt, inputs).unwrap();
}
