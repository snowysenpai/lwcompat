use eframe::egui;
use std::path::PathBuf;
use std::process::Command;

struct LwCompatApp {
    status: String,
}

impl Default for LwCompatApp {
    fn default() -> Self {
        Self {
            status: "Ready".to_owned(),
        }
    }
}

impl LwCompatApp {
    fn home_dir() -> Option<PathBuf> {
        std::env::var_os("HOME").map(PathBuf::from)
    }

    fn start_script() -> Option<PathBuf> {
        Some(
            Self::home_dir()?
                .join(".local")
                .join("share")
                .join("lwcompat")
                .join("start.sh"),
        )
    }

    fn log_file() -> Option<PathBuf> {
        Some(
            Self::home_dir()?
                .join(".local")
                .join("share")
                .join("lwcompat")
                .join("logs")
                .join("lwcompat.log"),
        )
    }

    fn launch_game(&mut self) {
        let Some(script) = Self::start_script() else {
            self.status = "HOME directory not found".to_owned();
            return;
        };

        if !script.exists() {
            self.status = format!("Launcher not found: {}", script.display());
            return;
        }

        match Command::new("bash").arg(&script).spawn() {
            Ok(_) => {
                self.status = "Launching Last War...".to_owned();
            }
            Err(err) => {
                self.status = format!("Launch failed: {err}");
            }
        }
    }

    fn open_logs(&mut self) {
        let Some(log) = Self::log_file() else {
            self.status = "Log path not found".to_owned();
            return;
        };

        if !log.exists() {
            self.status = "No log file yet".to_owned();
            return;
        }

        match Command::new("xdg-open").arg(&log).spawn() {
            Ok(_) => {
                self.status = "Opened logs".to_owned();
            }
            Err(err) => {
                self.status = format!("Could not open logs: {err}");
            }
        }
    }
}

impl eframe::App for LwCompatApp {
    fn ui(&mut self, ui: &mut egui::Ui, _frame: &mut eframe::Frame) {
        egui::CentralPanel::default().show(ui, |ui| {
            ui.add_space(30.0);

            ui.vertical_centered(|ui| {
                ui.heading("LWCompat");

                ui.add_space(8.0);
                ui.label("Last War: Survival Game");
                ui.add_space(20.0);

                ui.label(format!("Status: {}", self.status));

                ui.add_space(20.0);

                if ui
                    .add_sized([220.0, 48.0], egui::Button::new("PLAY"))
                    .clicked()
                {
                    self.launch_game();
                }

                ui.add_space(10.0);

                if ui.button("Open Logs").clicked() {
                    self.open_logs();
                }

                ui.add_space(30.0);
                ui.small("LWCompat v0.2.0-dev");
            });
        });
    }
}

fn main() -> eframe::Result {
    let options = eframe::NativeOptions::default();

    eframe::run_native(
        "LWCompat",
        options,
        Box::new(|_cc| Ok(Box::new(LwCompatApp::default()))),
    )
}
