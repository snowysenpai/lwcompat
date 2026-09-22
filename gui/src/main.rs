use eframe::egui;
use std::{
    fs,
    path::PathBuf,
    process::{Child, Command},
    time::{Duration, Instant},
};

const BG: egui::Color32 = egui::Color32::from_rgb(9, 10, 13);
const PANEL: egui::Color32 = egui::Color32::from_rgb(17, 19, 24);
const PANEL_ALT: egui::Color32 = egui::Color32::from_rgb(22, 24, 30);
const LOG_BG: egui::Color32 = egui::Color32::from_rgb(6, 7, 10);
const BORDER: egui::Color32 = egui::Color32::from_rgb(42, 46, 56);

const GREEN: egui::Color32 = egui::Color32::from_rgb(65, 220, 135);
const BLUE: egui::Color32 = egui::Color32::from_rgb(78, 165, 255);
const PURPLE: egui::Color32 = egui::Color32::from_rgb(170, 120, 255);
const ORANGE: egui::Color32 = egui::Color32::from_rgb(240, 175, 75);
const RED: egui::Color32 = egui::Color32::from_rgb(240, 90, 90);

struct LWCompat {
    status: String,
    logs: Vec<String>,
    last_refresh: Instant,

    game_found: bool,
    engine_ready: bool,
    logs_ready: bool,
    running: bool,

    fast_cache_installed: bool,
    fast_cache_enabled: bool,
    fast_cache_active: bool,
    fast_cache_busy: bool,
    fast_cache_error: bool,
    fast_cache_child: Option<Child>,
    last_fast_cache_refresh: Instant,

    logo: Option<egui::TextureHandle>,
}

impl LWCompat {
    fn new(ctx: &egui::Context) -> Self {
        let mut app = Self {
            status: "READY".into(),
            logs: Vec::new(),
            last_refresh: Instant::now() - Duration::from_secs(5),

            game_found: false,
            engine_ready: false,
            logs_ready: false,
            running: false,

            fast_cache_installed: false,
            fast_cache_enabled: false,
            fast_cache_active: false,
            fast_cache_busy: false,
            fast_cache_error: false,
            fast_cache_child: None,
            last_fast_cache_refresh:
                Instant::now() - Duration::from_secs(5),

            logo: Self::load_logo(ctx),
        };

        app.refresh();
        app
    }

    fn home() -> Option<PathBuf> {
        std::env::var_os("HOME").map(PathBuf::from)
    }

    fn app_dir() -> Option<PathBuf> {
        Some(Self::home()?.join(".local/share/lwcompat"))
    }

    fn logs_dir() -> Option<PathBuf> {
        Some(Self::app_dir()?.join("logs"))
    }

    fn start_script() -> Option<PathBuf> {
        Some(Self::app_dir()?.join("start.sh"))
    }

    fn fast_cache_ctl() -> Option<PathBuf> {
        Some(
            Self::app_dir()?
                .join("fast_asset_cache_ctl.sh"),
        )
    }

    fn game_dir() -> Option<PathBuf> {
        Some(
            Self::home()?.join(
                "Games/LastWar/drive_c/users/steamuser/AppData/Local/FunFly/Last War-Survival Game"
            ),
        )
    }

    fn logo_path() -> Option<PathBuf> {
        Some(
            Self::home()?
                .join(".local/share/icons/lastwar-lwcompat.png"),
        )
    }

    fn load_logo(ctx: &egui::Context) -> Option<egui::TextureHandle> {
        let path = Self::logo_path()?;

        let image = image::ImageReader::open(path)
            .ok()?
            .decode()
            .ok()?
            .to_rgba8();

        let size = [
            image.width() as usize,
            image.height() as usize,
        ];

        let pixels = image.into_raw();

        let color_image =
            egui::ColorImage::from_rgba_unmultiplied(size, &pixels);

        Some(ctx.load_texture(
            "lastwar-logo",
            color_image,
            egui::TextureOptions::LINEAR,
        ))
    }

    fn process_running(pattern: &str) -> bool {
        Command::new("pgrep")
            .arg("-f")
            .arg(pattern)
            .output()
            .map(|o| o.status.success())
            .unwrap_or(false)
    }

    fn refresh_fast_cache(&mut self) {
        let Some(ctl) = Self::fast_cache_ctl() else {
            self.fast_cache_installed = false;
            self.fast_cache_enabled = false;
            self.fast_cache_active = false;
            self.last_fast_cache_refresh = Instant::now();
            return;
        };

        if !ctl.exists() {
            self.fast_cache_installed = false;
            self.fast_cache_enabled = false;
            self.fast_cache_active = false;
            self.last_fast_cache_refresh = Instant::now();
            return;
        }

        match Command::new("bash")
            .arg(ctl)
            .arg("status")
            .output()
        {
            Ok(output) => {
                let text =
                    String::from_utf8_lossy(&output.stdout);

                self.fast_cache_installed =
                    output.status.success()
                    && !text.contains("NOT INSTALLED");

                self.fast_cache_enabled =
                    text.lines().any(|line| {
                        line.trim() == "Enabled : yes"
                    });

                self.fast_cache_active =
                    text.lines().any(|line| {
                        line.trim() == "Status  : ACTIVE"
                    });

                if !output.status.success() {
                    self.fast_cache_error = true;
                } else if !self.fast_cache_busy {
                    self.fast_cache_error = false;
                }
            }

            Err(_) => {
                self.fast_cache_installed = false;
                self.fast_cache_enabled = false;
                self.fast_cache_active = false;
                self.fast_cache_error = true;
            }
        }

        self.last_fast_cache_refresh = Instant::now();
    }

    fn toggle_fast_cache(&mut self) {
        if self.running
            || self.fast_cache_busy
            || !self.fast_cache_installed
        {
            return;
        }

        let Some(ctl) = Self::fast_cache_ctl() else {
            self.fast_cache_error = true;
            return;
        };

        let action = if self.fast_cache_active {
            "disable"
        } else {
            "enable"
        };

        match Command::new("bash")
            .arg(ctl)
            .arg(action)
            .env("LWCOMPAT_GUI", "1")
            .spawn()
        {
            Ok(child) => {
                self.fast_cache_child = Some(child);
                self.fast_cache_busy = true;
                self.fast_cache_error = false;
            }

            Err(_) => {
                self.fast_cache_error = true;
            }
        }
    }

    fn poll_fast_cache_action(&mut self) {
        let finished =
            match self.fast_cache_child.as_mut() {
                Some(child) => match child.try_wait() {
                    Ok(Some(status)) => {
                        Some(status.success())
                    }
                    Ok(None) => None,
                    Err(_) => Some(false),
                },
                None => None,
            };

        if let Some(success) = finished {
            self.fast_cache_child = None;
            self.fast_cache_busy = false;
            self.fast_cache_error = !success;

            self.refresh_fast_cache();
        }
    }

    fn refresh(&mut self) {
        self.game_found = Self::game_dir()
            .map(|p| p.exists())
            .unwrap_or(false);

        self.engine_ready = Self::start_script()
            .map(|p| p.exists())
            .unwrap_or(false);

        self.logs_ready = Self::logs_dir()
            .map(|p| p.exists())
            .unwrap_or(false);

        self.running =
            Self::process_running("LastWarLauncher.exe")
            || Self::process_running("LastWar.exe");

        if self.running {
            self.status = "RUNNING".into();
        } else if self.game_found && self.engine_ready {
            if self.status != "LAUNCHING" {
                self.status = "READY".into();
            }
        } else {
            self.status = "NOT READY".into();
        }

        self.logs = Self::read_logs();

        if !self.fast_cache_busy
            && self.last_fast_cache_refresh.elapsed()
                >= Duration::from_secs(2)
        {
            self.refresh_fast_cache();
        }

        self.last_refresh = Instant::now();
    }

    fn read_logs() -> Vec<String> {
        let Some(dir) = Self::logs_dir() else {
            return vec!["Log directory unavailable.".into()];
        };

        let lw =
            fs::read_to_string(dir.join("lwcompat.log")).unwrap_or_default();

        let proxy =
            fs::read_to_string(dir.join("proxy.log")).unwrap_or_default();

        let mut lines = Vec::new();

        if !lw.is_empty() {
            lines.push(
                "── LWCOMPAT ─────────────────────────────────────────".into(),
            );

            lines.extend(lw.lines().map(str::to_owned));
        }

        if !proxy.is_empty() {
            lines.push(String::new());

            lines.push(
                "── NATIVE BRIDGE ───────────────────────────────────".into(),
            );

            lines.extend(proxy.lines().map(str::to_owned));
        }

        if lines.len() > 450 {
            lines = lines.split_off(lines.len() - 450);
        }

        lines
    }

    fn launch(&mut self) {
        if self.running {
            return;
        }

        let Some(script) = Self::start_script() else {
            self.status = "ERROR".into();
            return;
        };

        if !script.exists() {
            self.status = "ERROR".into();
            return;
        }

        match Command::new("bash").arg(script).spawn() {
            Ok(_) => self.status = "LAUNCHING".into(),
            Err(_) => self.status = "ERROR".into(),
        }
    }

    fn open_logs(&self) {
        if let Some(dir) = Self::logs_dir() {
            let _ = Command::new("xdg-open").arg(dir).spawn();
        }
    }

    fn status_color(&self) -> egui::Color32 {
        match self.status.as_str() {
            "READY" => GREEN,
            "RUNNING" => BLUE,
            "LAUNCHING" => ORANGE,
            _ => RED,
        }
    }

    // Native vector status icon.
    // No Unicode glyph, no GIF, no missing-font squares.
    fn status_icon(
        ui: &mut egui::Ui,
        color: egui::Color32,
        ok: bool,
    ) {
        let size = 18.0;

        let (rect, _) = ui.allocate_exact_size(
            egui::vec2(size, size),
            egui::Sense::hover(),
        );

        let center = rect.center();
        let painter = ui.painter();

        painter.circle_filled(
            center,
            7.0,
            egui::Color32::from_rgba_unmultiplied(
                color.r(),
                color.g(),
                color.b(),
                25,
            ),
        );

        painter.circle_stroke(
            center,
            6.0,
            egui::Stroke::new(1.5, color),
        );

        if ok {
            let p1 = center + egui::vec2(-3.0, 0.0);
            let p2 = center + egui::vec2(-0.5, 2.5);
            let p3 = center + egui::vec2(4.0, -3.0);

            painter.line_segment(
                [p1, p2],
                egui::Stroke::new(1.8, color),
            );

            painter.line_segment(
                [p2, p3],
                egui::Stroke::new(1.8, color),
            );
        } else {
            painter.circle_filled(center, 2.0, color);
        }
    }

    fn state_dot(
        ui: &mut egui::Ui,
        color: egui::Color32,
        animated: bool,
    ) {
        let size = 18.0;

        let (rect, _) = ui.allocate_exact_size(
            egui::vec2(size, size),
            egui::Sense::hover(),
        );

        let center = rect.center();
        let painter = ui.painter();

        if animated {
            let time = ui.input(|i| i.time) as f32;
            let pulse = ((time * 3.0).sin() + 1.0) * 0.5;

            painter.circle_stroke(
                center,
                6.0 + pulse * 2.5,
                egui::Stroke::new(
                    1.0,
                    egui::Color32::from_rgba_unmultiplied(
                        color.r(),
                        color.g(),
                        color.b(),
                        100,
                    ),
                ),
            );
        }

        painter.circle_filled(center, 4.0, color);
    }

    fn status_card(
        ui: &mut egui::Ui,
        title: &str,
        value: &str,
        ok: bool,
    ) {
        let color = if ok { GREEN } else { ORANGE };

        egui::Frame::new()
            .fill(PANEL_ALT)
            .stroke(egui::Stroke::new(1.0, BORDER))
            .corner_radius(10.0)
            .inner_margin(egui::Margin::same(12))
            .show(ui, |ui| {
                ui.set_min_width(ui.available_width());

                ui.horizontal(|ui| {
                    Self::status_icon(ui, color, ok);

                    ui.add_space(4.0);

                    ui.vertical(|ui| {
                        ui.label(
                            egui::RichText::new(title)
                                .size(13.0)
                                .strong(),
                        );

                        ui.label(
                            egui::RichText::new(value)
                                .size(10.5)
                                .color(egui::Color32::GRAY),
                        );
                    });
                });
            });
    }

    fn fast_cache_card(
        &mut self,
        ui: &mut egui::Ui,
    ) {
        let (color, ok, value) =
            if self.fast_cache_busy {
                (ORANGE, false, "Authorization...")
            } else if self.fast_cache_error {
                (RED, false, "Action failed")
            } else if self.fast_cache_active {
                (GREEN, true, "ext4 + casefold")
            } else if self.fast_cache_installed {
                (ORANGE, false, "Btrfs fallback")
            } else {
                (RED, false, "Not installed")
            };

        let button_text =
            if self.fast_cache_busy {
                "..."
            } else if !self.fast_cache_installed {
                "N/A"
            } else if self.fast_cache_active {
                "ON"
            } else {
                "OFF"
            };

        let button_enabled =
            self.fast_cache_installed
            && !self.running
            && !self.fast_cache_busy;

        let mut clicked = false;

        egui::Frame::new()
            .fill(PANEL_ALT)
            .stroke(egui::Stroke::new(1.0, BORDER))
            .corner_radius(10.0)
            .inner_margin(egui::Margin::same(12))
            .show(ui, |ui| {
                ui.set_min_width(ui.available_width());

                ui.horizontal(|ui| {
                    Self::status_icon(
                        ui,
                        color,
                        ok,
                    );

                    ui.add_space(4.0);

                    ui.vertical(|ui| {
                        ui.label(
                            egui::RichText::new(
                                "Fast Cache"
                            )
                            .size(13.0)
                            .strong(),
                        );

                        ui.label(
                            egui::RichText::new(value)
                                .size(10.5)
                                .color(
                                    egui::Color32::GRAY
                                ),
                        );
                    });

                    ui.with_layout(
                        egui::Layout::right_to_left(
                            egui::Align::Center,
                        ),
                        |ui| {
                            let response =
                                ui.add_enabled(
                                    button_enabled,
                                    egui::Button::new(
                                        egui::RichText::new(
                                            button_text
                                        )
                                        .size(10.5)
                                        .strong(),
                                    )
                                    .min_size(
                                        egui::vec2(
                                            46.0,
                                            28.0,
                                        ),
                                    ),
                                );

                            clicked = response.clicked();
                        },
                    );
                });
            });

        if clicked {
            self.toggle_fast_cache();
        }
    }

    fn log_color(line: &str) -> egui::Color32 {
        let lower = line.to_ascii_lowercase();

        if lower.contains("error")
            || lower.contains("failed")
        {
            RED
        } else if line.contains("WARN") {
            ORANGE
        } else if line.contains("[API]") {
            BLUE
        } else if line.contains("[CDN]") {
            PURPLE
        } else if line.contains("HTTP 200")
            || line.contains("READY")
            || line.contains("18080 OK")
            || line.contains("18081 OK")
            || line.contains("Fast Asset Cache: ACTIVE")
        {
            GREEN
        } else if line.starts_with("──") {
            egui::Color32::from_rgb(110, 115, 130)
        } else {
            egui::Color32::from_rgb(185, 190, 200)
        }
    }
}

impl eframe::App for LWCompat {
    fn ui(
        &mut self,
        ui: &mut egui::Ui,
        _frame: &mut eframe::Frame,
    ) {
        self.poll_fast_cache_action();

        if self.last_refresh.elapsed() >= Duration::from_millis(500) {
            self.refresh();
        }

        ui.ctx()
            .request_repaint_after(Duration::from_millis(100));

        ui.visuals_mut().panel_fill = BG;

        egui::Frame::new()
            .inner_margin(egui::Margin {
                left: 24,
                right: 24,
                top: 0,
                bottom: 0,
            })
            .show(ui, |ui| {

                ui.add_space(14.0);

                // MAIN HERO
        egui::Frame::new()
            .fill(PANEL)
            .stroke(egui::Stroke::new(1.0, BORDER))
            .corner_radius(14.0)
            .inner_margin(egui::Margin::same(20))
            .show(ui, |ui| {

                // ------------------------------------------------
                // GAME INFO + PLAY
                // ------------------------------------------------

                ui.horizontal(|ui| {

                    // Game icon
                    egui::Frame::new()
                        .fill(egui::Color32::from_rgb(12, 13, 17))
                        .stroke(egui::Stroke::new(1.0, BORDER))
                        .corner_radius(14.0)
                        .inner_margin(egui::Margin::same(8))
                        .show(ui, |ui| {
                            if let Some(logo) = &self.logo {
                                ui.add(
                                    egui::Image::new((
                                        logo.id(),
                                        egui::vec2(92.0, 92.0),
                                    )),
                                );
                            }
                        });

                    ui.add_space(16.0);

                    // Game information
                    ui.vertical(|ui| {
                        ui.add_space(5.0);

                        ui.label(
                            egui::RichText::new(
                                "Last War: Survival Game"
                            )
                            .size(24.0)
                            .strong(),
                        );

                        ui.add_space(6.0);

                        ui.label(
                            egui::RichText::new(
                                "Native Linux compatibility layer"
                            )
                            .color(egui::Color32::GRAY),
                        );

                        ui.add_space(5.0);

                        ui.label(
                            egui::RichText::new(
                                "Dual bridge • GE-Proton • UMU"
                            )
                            .size(11.0)
                            .color(
                                egui::Color32::from_rgb(
                                    120, 125, 140
                                )
                            ),
                        );
                    });

                    // PLAY area aligned right
                    ui.with_layout(
                        egui::Layout::right_to_left(
                            egui::Align::Center
                        ),
                        |ui| {
                            let text = if self.running {
                                "GAME RUNNING"
                            } else if self.status == "LAUNCHING" {
                                "LAUNCHING..."
                            } else {
                                "PLAY"
                            };

                            let enabled =
                                self.game_found
                                && self.engine_ready
                                && !self.running
                                && self.status != "LAUNCHING";

                            if ui
                                .add_enabled(
                                    enabled,
                                    egui::Button::new(
                                        egui::RichText::new(text)
                                            .size(19.0)
                                            .strong(),
                                    )
                                    .min_size(
                                        egui::vec2(
                                            230.0,
                                            54.0,
                                        )
                                    ),
                                )
                                .clicked()
                            {
                                self.launch();
                            }
                        },
                    );
                });

                ui.add_space(20.0);
                ui.separator();
                ui.add_space(14.0);

                // ------------------------------------------------
                // SYSTEM STATUS TITLE + STATE
                // ------------------------------------------------

                ui.horizontal(|ui| {
                    ui.label(
                        egui::RichText::new("SYSTEM STATUS")
                            .size(11.0)
                            .strong()
                            .color(egui::Color32::GRAY),
                    );

                    ui.with_layout(
                        egui::Layout::right_to_left(
                            egui::Align::Center
                        ),
                        |ui| {
                            ui.label(
                                egui::RichText::new(
                                    &self.status
                                )
                                .size(11.0)
                                .strong()
                                .color(
                                    self.status_color()
                                ),
                            );

                            Self::state_dot(
                                ui,
                                self.status_color(),
                                self.status == "LAUNCHING",
                            );
                        },
                    );
                });

                ui.add_space(10.0);

                // ------------------------------------------------
                // ALL FOUR STATUS CARDS IN ONE ROW
                // ------------------------------------------------

                ui.columns(4, |cards| {
                    Self::status_card(
                        &mut cards[0],
                        "Game",
                        if self.game_found {
                            "Installation found"
                        } else {
                            "Not found"
                        },
                        self.game_found,
                    );

                    Self::status_card(
                        &mut cards[1],
                        "Engine",
                        if self.engine_ready {
                            "Compatibility ready"
                        } else {
                            "Unavailable"
                        },
                        self.engine_ready,
                    );

                    self.fast_cache_card(
                        &mut cards[2],
                    );

                    Self::status_card(
                        &mut cards[3],
                        "Activity",
                        if self.logs_ready {
                            "Live monitoring"
                        } else {
                            "Unavailable"
                        },
                        self.logs_ready,
                    );
                });
            });

        ui.add_space(16.0);

        // ------------------------------------------------
        // LIVE ACTIVITY
        // ------------------------------------------------

        ui.horizontal(|ui| {
            ui.label(
                egui::RichText::new("LIVE ACTIVITY")
                    .size(16.0)
                    .strong(),
            );

            Self::state_dot(ui, GREEN, true);

            ui.label(
                egui::RichText::new("LIVE")
                    .size(9.5)
                    .color(GREEN)
                    .strong(),
            );

            ui.with_layout(
                egui::Layout::right_to_left(
                    egui::Align::Center
                ),
                |ui| {
                    if ui.button("Open Logs").clicked() {
                        self.open_logs();
                    }

                    if ui.button("Refresh").clicked() {
                        self.refresh();
                    }
                },
            );
        });

        ui.add_space(7.0);

        // LOG TERMINAL
        egui::Frame::new()
            .fill(LOG_BG)
            .stroke(egui::Stroke::new(1.0, BORDER))
            .corner_radius(11.0)
            .inner_margin(egui::Margin::same(12))
            .show(ui, |ui| {
                egui::ScrollArea::vertical()
                    .stick_to_bottom(true)
                    .max_height(365.0)
                    .show(ui, |ui| {
                        for line in &self.logs {
                            ui.label(
                                egui::RichText::new(line)
                                    .monospace()
                                    .size(11.5)
                                    .color(
                                        Self::log_color(line)
                                    ),
                            );
                        }
                    });
            });

        ui.add_space(8.0);

        
            });
    }
}

fn main() -> eframe::Result {
    let options = eframe::NativeOptions {
        viewport:
            egui::ViewportBuilder::default()
                .with_title("LWCompat")
                .with_inner_size([1080.0, 760.0])
                .with_min_inner_size([1080.0, 760.0])
                .with_max_inner_size([1080.0, 760.0])
                .with_resizable(false),
        ..Default::default()
    };

    eframe::run_native(
        "LWCompat",
        options,
        Box::new(|cc| {
            let mut visuals = egui::Visuals::dark();

            visuals.panel_fill = BG;
            visuals.window_fill = BG;

            cc.egui_ctx.set_visuals(visuals);

            Ok(Box::new(
                LWCompat::new(&cc.egui_ctx)
            ))
        }),
    )
}
