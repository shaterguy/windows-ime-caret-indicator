const { app, BrowserWindow } = require("electron");
const path = require("path");

app.commandLine.appendSwitch("force-renderer-accessibility");

function createWindow() {
  const window = new BrowserWindow({
    width: 680,
    height: 440,
    show: false,
    title: "WICI Electron Caret Host",
    webPreferences: {
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true
    }
  });

  window.loadFile(path.join(__dirname, "index.html"));
  window.once("ready-to-show", () => {
    window.show();
    window.focus();
  });
}

app.whenReady().then(createWindow);
app.on("window-all-closed", () => app.quit());
