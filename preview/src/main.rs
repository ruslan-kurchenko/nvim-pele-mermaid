//! Animated Neovim workflow illustration, not a recording. All diagrams are real Pele output.
use fframes::{
    AudioMap, Duration, FFramesContext, Frame, MediaDirectory, Previewer, RenderOptions, Svgr, Video,
};
use std::{
    error::Error,
    fs::{self, File},
    io::Write,
    path::Path,
    process::{Command, Stdio},
};

const FONT: &str = "Maple Mono NF";
const DOCUMENT: &str = include_str!("../architecture.md");
const ADDED_LINE: &str = "  C --> D[Worker]";
const SECONDS: usize = 24;
const GIF_FPS: usize = 15;

type Result<T, E = Box<dyn Error>> = std::result::Result<T, E>;

struct Diagram {
    svg: String,
    width: f64,
    height: f64,
}
impl Diagram {
    fn fit(&self, x: f64, y: f64, width: f64, height: f64) -> String {
        let scale = (width / self.width).min(height / self.height);
        format!("translate({} {}) scale({scale})", x + (width - self.width * scale) / 2.0, y + (height - self.height * scale) / 2.0)
    }
}
struct Preview {
    before: Diagram,
    after: Diagram,
    other: Diagram,
    source_lines: Vec<String>,
    edited_lines: Vec<String>,
    edit_steps: Vec<String>,
    insert_row: usize,
    first_focus_row: usize,
    other_focus_row: usize,
}

impl Video for Preview {
    const FPS: usize = 30;
    const WIDTH: usize = 1600;
    const HEIGHT: usize = 1000;
    fn duration(&self) -> Duration<'_> {
        Duration::Seconds(SECONDS as f32)
    }
    fn audio(&self) -> AudioMap<'_> {
        AudioMap::none()
    }
    fn render_frame<'a>(&'a self, frame: Frame, _ctx: &FFramesContext<'a, '_>) -> Svgr<'a> {
        let time = frame.seconds();
        let reading = (2.5..6.5).contains(&time) || time >= 21.3;
        let floating = (7.5..10.5).contains(&time);
        let split = (11.5..20.5).contains(&time);
        let editing = (13.0..15.2).contains(&time);
        let added = time >= 13.0;
        let regenerated = time >= 15.4;
        let other_focused = time >= 18.5;
        let edit_index = (((time - 13.0) / 2.2).clamp(0.0, 1.0) * (self.edit_steps.len() - 1) as f32) as usize;
        let cursor_row = if other_focused { self.other_focus_row + 1 }
            else if added { self.insert_row } else { self.first_focus_row };
        let lines = if added { &self.edited_lines } else { &self.source_lines };
        let code: Vec<_> = lines.iter().enumerate().map(|(index, line)| {
            let line = if index == self.insert_row && added { &self.edit_steps[edit_index] } else { line };
            let color = if index == self.insert_row && added { "#a6e3a1" }
                else if line.starts_with('#') || line.starts_with("graph") { "#cba6f7" }
                else if line.starts_with("```") { "#7f849c" } else { "#cdd6f4" };
            fframes::svgr!(<g>
                <text x="105" y={285 + index * 23} text-anchor="end" fill="#7f849c" font-size="19">{(index + 1).to_string()}</text>
                <text x="128" y={285 + index * 23} fill={color} font-size="22" xml:space="preserve">{line.as_str()}</text>
            </g>)
        }).collect();
        let current = if other_focused { &self.other } else if regenerated { &self.after } else { &self.before };
        let (keys, explanation) = if time < 2.5 {
            ("architecture.md", "Open any Markdown file containing Mermaid fences.")
        } else if time < 6.5 {
            ("Leader m m", "See the diagrams in the document, alongside your notes.")
        } else if time < 7.5 {
            ("Leader m m", "Back to the same Markdown source. Nothing was rewritten.")
        } else if time < 10.5 {
            ("Leader m p", "Just need this one? Preview the diagram under your cursor.")
        } else if time < 11.5 {
            ("Leader m p", "Close the focused preview. Keep your place in the source.")
        } else if time < 13.0 {
            ("Leader m s", "Keep the focused diagram beside your Markdown.")
        } else if time < 18.5 {
            (if editing { "Typing…" } else { "No refresh command" }, "Add a node. The side preview regenerates automatically.")
        } else if time < 20.5 {
            ("Move the cursor", "Another Mermaid fence. The side preview follows.")
        } else if time < 21.3 {
            ("Leader m s", "Close the side preview.")
        } else {
            ("Leader m m", "Read the updated diagrams as part of the Markdown file.")
        };
        let first = if regenerated { &self.after } else { &self.before };
        fframes::svgr!(
            <svg xmlns="http://www.w3.org/2000/svg" width="1600" height="1000" font-family={FONT}>
                <defs>
                    <clipPath id="document"><rect x="74" y="250" width={if split { 710 } else { 1452 }} height="592" /></clipPath>
                </defs>
                <rect width="1600" height="1000" fill="#181825" />
                <text x="72" y="101" font-size="47" font-weight="700" fill="#cdd6f4">"Mermaid diagrams, inside your Markdown."</text>
                <text x="76" y="148" font-size="24" fill="#bac2de">"Preview the document. Focus a diagram. Edit with a live preview."</text>
                <rect x="72" y="195" width="1456" height="700" rx="10" fill="#1e1e2e" stroke="#585b70" />
                <path d="M82 195H1518Q1528 195 1528 205V249H72V205Q72 195 82 195" fill="#313244" />
                <text x="99" y="229" font-size="21" fill="#cdd6f4">{if reading { "[Mermaid] architecture.md" } else { "architecture.md" }}</text>
                <text x="1496" y="229" text-anchor="end" font-size="18" fill="#a6adc8">"Neovim / Catppuccin Mocha"</text>
                <g clip-path="url(#document)">
                    <g opacity={if reading { 0.0 } else { 1.0 }}>
                        <rect x="121" y={265 + cursor_row * 23} width={if split { 650 } else { 1385 }} height="24" fill="#313244" />
                        {code}
                        <rect x={if added && !other_focused { 128.0 + self.edit_steps[edit_index].len() as f32 * 13.2 } else { 154.4 }} y={266 + cursor_row * 23} width="12" height="22" fill="#f5e0dc" opacity={if (time * 2.0).fract() < 0.65 { 0.75 } else { 0.0 }} />
                    </g>
                    <g opacity={if reading { 1.0 } else { 0.0 }}>
                        <text x="128" y="285" font-size="22" fill="#cba6f7">{self.source_lines[0].as_str()}</text>
                        <text x="128" y="331" font-size="22" fill="#cdd6f4">{self.source_lines[2].as_str()}</text>
                        <text x="128" y="354" font-size="22" fill="#cdd6f4">{self.source_lines[3].as_str()}</text>
                        <text x="128" y="400" font-size="22" fill="#cba6f7">{self.source_lines[5].as_str()}</text>
                        <g transform={first.fit(150.0, 430.0, 1280.0, 125.0)}>{Svgr::from(first.svg.as_str())}</g>
                        <text x="128" y="596" font-size="22" fill="#cdd6f4">{self.source_lines[13].as_str()}</text>
                        <text x="128" y="642" font-size="22" fill="#cba6f7">{self.source_lines[15].as_str()}</text>
                        <g transform={self.other.fit(150.0, 665.0, 1280.0, 115.0)}>{Svgr::from(self.other.svg.as_str())}</g>
                        <text x="128" y="823" font-size="22" fill="#cdd6f4">{self.source_lines[23].as_str()}</text>
                    </g>
                </g>
                <g opacity={if split { 1.0 } else { 0.0 }}>
                    <rect x="790" y="250" width="736" height="592" fill="#1e1e2e" />
                    <path d="M790 250V895" stroke="#585b70" />
                    <g transform={current.fit(825.0, 330.0, 660.0, 420.0)}>{Svgr::from(current.svg.as_str())}</g>
                </g>
                <g opacity={if floating { 1.0 } else { 0.0 }}>
                    <rect x="410" y="365" width="850" height="360" rx="8" fill="#1e1e2e" stroke="#89b4fa" stroke-width="2" />
                    <rect x="705" y="353" width="260" height="28" fill="#1e1e2e" />
                    <text x="835" y="374" text-anchor="middle" font-size="22" fill="#89b4fa">"Mermaid Preview"</text>
                    <g transform={self.before.fit(455.0, 405.0, 760.0, 275.0)}>{Svgr::from(self.before.svg.as_str())}</g>
                </g>
                <rect x="73" y="843" width="1454" height="50" fill="#313244" />
                <text x="98" y="875" font-size="21" fill="#a6e3a1">{if editing { "INSERT" } else { "NORMAL" }}</text>
                <text x="225" y="875" font-size="20" fill="#cdd6f4">{if reading { "[Mermaid] architecture.md" } else if added { "architecture.md [+]" } else { "architecture.md" }}</text>
                <text x="1495" y="875" text-anchor="end" font-size="18" fill="#a6adc8">{if split { "mermaid-preview" } else { "markdown" }}</text>
                <text x="75" y="941" font-size="23" fill="#a6e3a1">{keys}</text>
                <text x="365" y="941" font-size="21" fill="#cdd6f4">{explanation}</text>
                <text x="76" y="981" font-size="16" fill="#a6adc8">"Illustrated workflow / actual Pele renders / example mappings: use your leader key / nvim-pele-mermaid"</text>
            </svg>
        )
    }
}

fn render_diagram(root: &Path, source: &str) -> Result<Diagram> {
    let bun = std::env::var_os("BUN").unwrap_or_else(|| "bun".into());
    let mut child = Command::new(bun)
        .arg(root.join("scripts/renderer.js"))
        .current_dir(root)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()?;
    child.stdin.take().ok_or("Renderer stdin unavailable")?.write_all(serde_json::to_string(&serde_json::json!({
        "text": source, "theme": "dark", "format": "svg", "options": {
            "padding": 20, "transparent": true,
            "bg": "#1e1e2e", "fg": "#cdd6f4", "line": "#89b4fa",
            "accent": "#cba6f7", "muted": "#a6adc8", "surface": "#313244", "border": "#585b70"
        }
    }))?.as_bytes())?;
    let rendered = child.wait_with_output()?;
    let response: serde_json::Value = serde_json::from_slice(&rendered.stdout)?;
    if !rendered.status.success() || response.get("error").is_some() {
        return Err(format!("Pele renderer failed: {response}").into());
    }
    let mut svg = response["output"]
        .as_str()
        .ok_or("Renderer returned no SVG")?
        .to_owned();
    let document = roxmltree::Document::parse(&svg)?;
    let element = document.root_element();
    let width: f64 = element
        .attribute("width")
        .ok_or("SVG has no width")?
        .parse()?;
    let height: f64 = element
        .attribute("height")
        .ok_or("SVG has no height")?
        .parse()?;
    // Keep intrinsic dimensions so the same real diagram fits inline, float, and split surfaces.
    // fframes loads these same fonts from media; do not parse megabytes of embedded web fonts every frame.
    let embedded: Vec<_> = element
        .children()
        .filter(|node| node.attribute("data-pele-fonts").is_some())
        .map(|node| node.range())
        .collect();
    for range in embedded.into_iter().rev() {
        svg.replace_range(range, "");
    }
    Ok(Diagram { svg, width, height })
}

fn inspect(video: &Preview, options: &RenderOptions<'_, '_>, directory: &Path) -> Result<()> {
    fs::create_dir_all(directory)?;
    let mut previewer = Previewer::new(video, options)?;
    for frame in 0..SECONDS * Preview::FPS {
        let report = previewer.inspect(frame)?;
        if !report.diagnostics.is_empty() {
            return Err(format!("Frame {}: {}", frame, serde_json::to_string(&report)?).into());
        }
    }
    // fframes 1.4 caches clipped groups across opacity changes; render each scene afresh.
    let mut renderer = fframes::CpuFrameRenderer::new(0);
    for time in [0.0, 3.5, 6.8, 8.5, 12.0, 14.0, 16.0, 19.0, 22.5] {
        let frame = (time * Preview::FPS as f32) as usize;
        previewer
            .render(frame, &mut renderer)?
            .save_png(directory.join(format!("{time:.1}s.png")))?;
    }
    println!(
        "Inspected all {} frames; keyframes in {}",
        SECONDS * Preview::FPS,
        directory.display()
    );
    Ok(())
}

fn render_gif(video: &Preview, options: &RenderOptions<'_, '_>, path: &Path) -> Result<()> {
    let options = RenderOptions {
        scale_resolution: 0.7,
        ..options.clone()
    };
    let mut previewer = Previewer::new(video, &options)?;
    let mut renderer = fframes::CpuFrameRenderer::new(0);
    let mut encoder = gif::Encoder::new(File::create(path)?, 1120, 700, &[])?;
    encoder.set_repeat(gif::Repeat::Infinite)?;
    let mut previous = Vec::<u8>::new();
    let mut pixels = Vec::new();
    for index in 0..SECONDS * GIF_FPS {
        let image = previewer.render(index * Preview::FPS / GIF_FPS, &mut renderer)?;
        let (width, height) = (image.width as usize, image.height as usize);
        let (mut left, mut top, mut right, mut bottom) = (width, height, 0, 0);
        if previous.is_empty() {
            (left, top, right, bottom) = (0, 0, width, height);
        } else {
            for (pixel, (new, old)) in image
                .pixels
                .chunks_exact(4)
                .zip(previous.chunks_exact(4))
                .enumerate()
            {
                if new != old {
                    left = left.min(pixel % width);
                    top = top.min(pixel / width);
                    right = right.max(pixel % width + 1);
                    bottom = bottom.max(pixel / width + 1);
                }
            }
        }
        pixels.clear();
        if right == 0 {
            (left, top, right, bottom) = (0, 0, 1, 1);
            pixels.extend_from_slice(&[0, 0, 0, 0]);
        } else {
            pixels.reserve((right - left) * (bottom - top) * 4);
            for row in top..bottom {
                pixels.extend_from_slice(
                    &image.pixels[(row * width + left) * 4..(row * width + right) * 4],
                );
            }
        }
        let mut frame = gif::Frame::from_rgba_speed(
            (right - left) as u16,
            (bottom - top) as u16,
            &mut pixels,
            10,
        );
        frame.left = left as u16;
        frame.top = top as u16;
        frame.delay = (((index + 1) * 100 / GIF_FPS) - (index * 100 / GIF_FPS)) as u16;
        frame.dispose = gif::DisposalMethod::Keep;
        encoder.write_frame(&frame)?;
        previous = image.pixels;
    }
    println!("{} — {SECONDS}s, 1120×700, 15 fps", path.display());
    Ok(())
}

fn render_mp4(video: &Preview, options: &RenderOptions<'_, '_>, path: &Path) -> Result<()> {
    // Use the installed encoder rather than fframes' prebuilt FFmpeg, whose x264
    // ABI can differ from the host. Every video frame is still rendered by fframes.
    let mut encoder = Command::new("ffmpeg")
        .args([
            "-hide_banner",
            "-loglevel",
            "error",
            "-y",
            "-f",
            "rawvideo",
            "-pixel_format",
            "rgba",
            "-video_size",
            "1600x1000",
            "-framerate",
            "30",
            "-i",
            "pipe:0",
            "-an",
            "-c:v",
            "libx264",
            "-threads",
            "2",
            "-preset",
            "medium",
            "-crf",
            "20",
            "-pix_fmt",
            "yuv420p",
            "-movflags",
            "+faststart",
        ])
        .arg(path)
        .stdin(Stdio::piped())
        .spawn()?;
    let mut input = encoder.stdin.take().ok_or("FFmpeg stdin unavailable")?;
    let rendered = (|| -> Result<()> {
        let mut previewer = Previewer::new(video, options)?;
        let mut renderer = fframes::CpuFrameRenderer::new(0);
        for frame in 0..SECONDS * Preview::FPS {
            input.write_all(&previewer.render(frame, &mut renderer)?.pixels)?;
        }
        Ok(())
    })();
    drop(input);
    if rendered.is_err() {
        let _ = encoder.kill();
    }
    let status = encoder.wait()?;
    rendered?;
    if !status.success() {
        return Err(format!("FFmpeg encoding failed: {status}").into());
    }
    println!("{} — {SECONDS}s, 1600×1000, H.264, 30 fps", path.display());
    Ok(())
}

fn main() -> Result<()> {
    let command = std::env::args().nth(1).unwrap_or_else(|| "all".into());
    if !["all", "inspect", "poster", "mp4", "gif"].contains(&command.as_str()) {
        return Err("Usage: pele-readme-preview [all|inspect|poster|mp4|gif]".into());
    }
    let root = Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .ok_or("Preview root unavailable")?;
    let source_lines: Vec<String> = DOCUMENT.lines().map(str::to_owned).collect();
    let fences: Vec<usize> = source_lines.iter().enumerate().filter_map(|(i, line)| (line == "```mermaid").then_some(i)).collect();
    let first_start = fences[0] + 1;
    let first_end = first_start + source_lines[first_start..].iter().position(|line| line == "```").ok_or("Unclosed demo fence")?;
    let second_start = fences[1] + 1;
    let second_end = second_start + source_lines[second_start..].iter().position(|line| line == "```").ok_or("Unclosed demo fence")?;
    let first_source = source_lines[first_start..first_end].join("\n");
    let other_source = source_lines[second_start..second_end].join("\n");
    let updated = format!("{first_source}\n{ADDED_LINE}");
    let mut edited_lines = source_lines.clone();
    edited_lines.insert(first_end, ADDED_LINE.to_owned());
    let video = Preview {
        before: render_diagram(root, &first_source)?,
        after: render_diagram(root, &updated)?,
        other: render_diagram(root, &other_source)?,
        source_lines,
        edited_lines,
        edit_steps: (0..=ADDED_LINE.len()).map(|count| ADDED_LINE[..count].to_owned()).collect(),
        insert_row: first_end,
        first_focus_row: first_start + 1,
        other_focus_row: second_start + 1,
    };
    let fonts = MediaDirectory::read_folder(root.join("assets/fonts"))?;
    let media = fonts.process_media_source()?;
    let options = RenderOptions {
        media: Some(&media),
        default_font: FONT,
        load_system_fonts: false,
        ..Default::default()
    };
    if command == "all" || command == "inspect" {
        inspect(&video, &options, &root.join("preview/target/inspection"))?;
    }
    if command == "all" || command == "poster" {
        Previewer::new(&video, &options)?
            .render(480, &mut fframes::CpuFrameRenderer::new(0))?
            .save_png(root.join("assets/preview.png"))?;
    }
    if command == "all" || command == "mp4" {
        render_mp4(&video, &options, &root.join("assets/preview.mp4"))?;
    }
    if command == "all" || command == "gif" {
        render_gif(&video, &options, &root.join("assets/preview.gif"))?;
    }
    Ok(())
}
