// Ani Watch - a Caelestia (Quickshell) plugin that drives ani-cli.
// Requires: ani-cli, mpv, and a terminal emulator (default: konsole).
//
// Toggle the window with:  caelestia shell ipc call aniwatch toggle
// (bind that command in Nexus -> Shortcuts -> add a command shortcut)
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Scope {
    id: root

    property bool open: false
    property string status: ""

    // Terminal used to host ani-cli (it needs a tty for its menus).
    // Change to e.g. ["kitty", "-e"] or ["alacritty", "-e"] if you prefer.
    readonly property var terminal: ["kitty", "-e"]

    function run(args) {
        if (runner.running) {
            root.status = "ani-cli is already running";
            return;
        }
        runner.command = root.terminal.concat(["ani-cli"], args);
        runner.running = true;
        root.status = "Launching...";
    }

    function watch(query, episode, dub, quality) {
        const q = query.trim();
        if (q === "") {
            root.status = "Type an anime name first";
            return;
        }
        let args = ["-S", "1"];          // pick the first search result
        if (episode.trim() !== "")
            args = args.concat(["-e", episode.trim()]);
        if (dub)
            args.push("--dub");
        if (quality !== "best")
            args = args.concat(["-q", quality]);
        args.push(q);
        root.run(args);
    }

    // "Continue watching" uses ani-cli's own history.
    function continueWatching() {
        root.run(["-c"]);
    }

    Process {
        id: runner

        onExited: (code, status) => {
            root.status = code === 0 ? "" : "ani-cli exited with code " + code;
        }
    }

    IpcHandler {
        target: "aniwatch"

        function toggle(): void {
            root.open = !root.open;
        }

        function show(): void {
            root.open = true;
        }

        function hide(): void {
            root.open = false;
        }
    }

    LazyLoader {
        active: root.open

        PanelWindow {
            id: win

            implicitWidth: 460
            implicitHeight: 250
            color: "transparent"
            exclusionMode: ExclusionMode.Ignore
            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand

            Rectangle {
                anchors.fill: parent
                radius: 16
                color: "#1e2327"
                border.color: "#3a444b"
                border.width: 1

                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: 16
                    spacing: 10

                    Text {
                        text: "Ani Watch"
                        color: "#e0e0e0"
                        font.pixelSize: 18
                        font.bold: true
                    }

                    TextField {
                        id: search

                        Layout.fillWidth: true
                        placeholderText: "Anime name"
                        focus: true
                        onAccepted: root.watch(search.text, episode.text, dub.checked, quality.currentText)
                        Keys.onEscapePressed: root.open = false
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 10

                        TextField {
                            id: episode

                            Layout.preferredWidth: 110
                            placeholderText: "Episode"
                            inputMethodHints: Qt.ImhDigitsOnly
                            onAccepted: root.watch(search.text, episode.text, dub.checked, quality.currentText)
                            Keys.onEscapePressed: root.open = false
                        }

                        ComboBox {
                            id: quality

                            model: ["best", "1080", "720", "480"]
                        }

                        CheckBox {
                            id: dub

                            text: "Dub"
                        }
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 10

                        Button {
                            text: "Watch"
                            onClicked: root.watch(search.text, episode.text, dub.checked, quality.currentText)
                        }

                        Button {
                            text: "Continue"
                            onClicked: root.continueWatching()
                        }

                        Item {
                            Layout.fillWidth: true
                        }

                        Button {
                            text: "Close"
                            onClicked: root.open = false
                        }
                    }

                    Text {
                        Layout.fillWidth: true
                        text: root.status
                        color: "#f2b8b5"
                        font.pixelSize: 12
                        elide: Text.ElideRight
                        visible: root.status !== ""
                    }
                }
            }
        }
    }
}
