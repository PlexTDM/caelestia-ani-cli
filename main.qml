// Ani Watch - desktop widget: search bar -> anime list -> episode grid -> play.
// Sub only, best quality. Search/episode lists are fetched with curl using the
// endpoint + user-agent read from your installed ani-cli; playback is ani-cli itself.
// Requires: ani-cli and its own deps (mpv, curl, botan, fzf).
//
// Optional IPC (bind in Nexus -> Shortcuts):
//   caelestia shell ipc call aniwatch toggle | show | hide
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Scope {
    id: root

    // ---- tweakables -------------------------------------------------------
    property bool shown: true
    readonly property int widgetWidth: 380
    readonly property int widgetHeight: 540
    readonly property int marginTop: 80
    readonly property int marginRight: 40
    // The window sits on WlrLayer.Bottom (above the wallpaper, below windows).
    // If typing in the search bar doesn't work on your setup, change it to
    // WlrLayer.Top in the PanelWindow below.

    // ---- state ------------------------------------------------------------
    property string view: "search"      // "search" | "episodes"
    property string pendingQuery: ""
    property var pendingPick: null
    property var results: []            // [{id, name, eps, year, index, query}]
    property var picked: null
    property var episodes: []           // ["1","2",...] ascending
    property string message: ""
    property string playingEp: ""
    property string lastErr: ""
    readonly property bool loading: searchProc.running || epsProc.running

    readonly property string searchGql: "query( $search: SearchInput $limit: Int $page: Int $translationType: VaildTranslationTypeEnumType $countryOrigin: VaildCountryOriginEnumType ) { shows( search: $search limit: $limit page: $page translationType: $translationType countryOrigin: $countryOrigin ) { edges { _id name availableEpisodes airedStart __typename } }}"
    readonly property string epsGql: "query ($showId: String!) { show( _id: $showId ) { _id availableEpisodesDetail }}"

    // POSTs $1 as JSON to the API ani-cli is configured with.
    readonly property string apiScript: `
f=$(command -v ani-cli) || { echo '{"error":"ani-cli not found"}'; exit 0; }
api=$(grep -m1 '^allanime_api=' "$f" | cut -d'"' -f2)
refr=$(grep -m1 '^allanime_refr=' "$f" | cut -d'"' -f2)
agent=$(grep -m1 '^agent=' "$f" | cut -d'"' -f2)
[ -n "$api" ] || api=https://api.mkissa.net
[ -n "$refr" ] || refr=https://mkissa.to
exec curl -s --max-time 20 -e "$refr" -A "$agent" -H 'Content-Type: application/json' -X POST "$api/api" --data "$1"
`

    // ---- search -----------------------------------------------------------
    function startSearch(text) {
        // Same normalisation ani-cli applies to its query argument.
        const q = text.replace(/["\\]/g, "").trim().replace(/^-+/, "").replace(/\s+/g, "+");
        if (q === "") {
            root.results = [];
            root.message = "";
            return;
        }
        if (searchProc.running) {
            root.pendingQuery = q;
            return;
        }
        runSearch(q);
    }

    function runSearch(q) {
        root.pendingQuery = "";
        root.message = "";
        searchProc.q = q;
        const body = JSON.stringify({
            variables: {
                search: { allowAdult: false, allowUnknown: false, query: q },
                limit: 40, page: 1, translationType: "sub", countryOrigin: "ALL"
            },
            query: root.searchGql
        });
        searchProc.command = ["sh", "-c", root.apiScript, "aa", body];
        searchProc.running = true;
    }

    function onSearchDone(text, q) {
        let j;
        try {
            j = JSON.parse(text);
        } catch (e) {
            root.results = [];
            root.message = "Search failed (no response)";
            return;
        }
        if (j.error) {
            root.results = [];
            root.message = j.error;
            return;
        }
        const edges = (j.data && j.data.shows && j.data.shows.edges) || [];
        // Mirror ani-cli's own filtering so "-S <n>" lands on the same show:
        // it keeps only shows with >=1 sub episode and a usable airedStart.
        const kept = edges.filter(e => {
            const ok = e.availableEpisodes && e.availableEpisodes.sub > 0;
            const a = e.airedStart;
            const dated = a && typeof a === "object" && (Object.keys(a).length === 0 || typeof a.year === "number");
            return ok && dated;
        });
        root.results = kept.map((e, i) => ({
            id: e._id,
            name: e.name,
            eps: e.availableEpisodes.sub,
            year: (e.airedStart && e.airedStart.year) || 0,
            index: i + 1,
            query: q
        }));
        if (root.results.length === 0)
            root.message = "No results";
    }

    // ---- episodes ---------------------------------------------------------
    function openAnime(r) {
        root.picked = r;
        root.episodes = [];
        root.view = "episodes";
        root.message = "";
        if (epsProc.running) {
            root.pendingPick = r;
            return;
        }
        runEpisodes(r);
    }

    function runEpisodes(r) {
        root.pendingPick = null;
        epsProc.showId = r.id;
        const body = JSON.stringify({ variables: { showId: r.id }, query: root.epsGql });
        epsProc.command = ["sh", "-c", root.apiScript, "aa", body];
        epsProc.running = true;
    }

    function onEpsDone(text, showId) {
        if (!root.picked || root.picked.id !== showId)
            return;
        let j;
        try {
            j = JSON.parse(text);
        } catch (e) {
            root.message = "Couldn't load episodes";
            return;
        }
        const d = j.data && j.data.show && j.data.show.availableEpisodesDetail;
        const list = (d && d.sub) ? d.sub.slice() : [];
        list.sort((a, b) => parseFloat(a) - parseFloat(b));
        root.episodes = list;
        if (list.length === 0)
            root.message = "No sub episodes";
    }

    // ---- playback (ani-cli, sub, best quality) ----------------------------
    function play(ep) {
        if (playProc.running || !root.picked)
            return;
        root.message = "";
        root.lastErr = "";
        root.playingEp = ep;
        playProc.command = [
            "env", "ANI_CLI_MODE=sub", "TERM=xterm",
            "ani-cli", "--exit-after-play",
            "-S", String(root.picked.index),
            "-e", ep,
            "-q", "best",
            root.picked.query
        ];
        playProc.running = true;
    }

    function clean(line) {
        return line.replace(/\x1b\[[0-9;?]*[A-Za-z]/g, "").replace(/\r/g, "").trim();
    }

    Process {
        id: searchProc

        property string q: ""

        stdout: StdioCollector {
            id: searchOut
        }

        onExited: {
            root.onSearchDone(searchOut.text, searchProc.q);
            if (root.pendingQuery !== "")
                root.runSearch(root.pendingQuery);
        }
    }

    Process {
        id: epsProc

        property string showId: ""

        stdout: StdioCollector {
            id: epsOut
        }

        onExited: {
            root.onEpsDone(epsOut.text, epsProc.showId);
            if (root.pendingPick)
                root.runEpisodes(root.pendingPick);
        }
    }

    Process {
        id: playProc

        // mpv runs in the foreground here; drop its output line by line.
        stdout: SplitParser {
            onRead: line => {}
        }
        stderr: SplitParser {
            onRead: line => {
                const c = root.clean(line);
                if (c !== "")
                    root.lastErr = c;
            }
        }

        onExited: code => {
            root.playingEp = "";
            root.message = code === 0 ? "" : (root.lastErr || ("ani-cli exited with code " + code));
        }
    }

    IpcHandler {
        target: "aniwatch"

        function toggle(): void {
            root.shown = !root.shown;
        }

        function show(): void {
            root.shown = true;
        }

        function hide(): void {
            root.shown = false;
        }
    }

    // ---- UI ---------------------------------------------------------------
    LazyLoader {
        active: root.shown

        PanelWindow {
            anchors {
                top: true
                right: true
            }
            margins {
                top: root.marginTop
                right: root.marginRight
            }
            implicitWidth: root.widgetWidth
            implicitHeight: root.widgetHeight
            color: "transparent"
            exclusionMode: ExclusionMode.Ignore
            WlrLayershell.namespace: "aniwatch"
            WlrLayershell.layer: WlrLayer.Bottom
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand

            Rectangle {
                anchors.fill: parent
                radius: 18
                color: Qt.rgba(0.12, 0.137, 0.153, 0.94)
                border.color: "#3a444b"
                border.width: 1

                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: 14
                    spacing: 10

                    TextField {
                        id: search

                        Layout.fillWidth: true
                        placeholderText: "Search anime..."
                        placeholderTextColor: "#8a949b"
                        color: "#e0e0e0"
                        font.pixelSize: 15
                        selectByMouse: true
                        leftPadding: 14
                        background: Rectangle {
                            radius: 12
                            color: "#2a3238"
                            border.color: search.activeFocus ? "#8ab4f8" : "transparent"
                            border.width: 1
                        }
                        onTextEdited: {
                            root.view = "search";
                            debounce.restart();
                        }
                        onAccepted: {
                            debounce.stop();
                            root.view = "search";
                            root.startSearch(search.text);
                        }

                        Timer {
                            id: debounce

                            interval: 450
                            onTriggered: root.startSearch(search.text)
                        }
                    }

                    // Episode view header
                    RowLayout {
                        Layout.fillWidth: true
                        visible: root.view === "episodes" && root.picked !== null
                        spacing: 8

                        Rectangle {
                            Layout.preferredWidth: 32
                            Layout.preferredHeight: 32
                            radius: 16
                            color: backArea.containsMouse ? "#3a444b" : "#2a3238"

                            Text {
                                anchors.centerIn: parent
                                text: "←"
                                color: "#e0e0e0"
                                font.pixelSize: 16
                            }

                            MouseArea {
                                id: backArea

                                anchors.fill: parent
                                hoverEnabled: true
                                onClicked: root.view = "search"
                            }
                        }

                        Text {
                            Layout.fillWidth: true
                            text: root.picked ? root.picked.name : ""
                            color: "#e0e0e0"
                            font.pixelSize: 14
                            font.bold: true
                            elide: Text.ElideRight
                        }

                        Text {
                            text: root.episodes.length > 0 ? root.episodes.length + " eps · sub" : ""
                            color: "#8a949b"
                            font.pixelSize: 12
                        }
                    }

                    // Results list
                    ListView {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        visible: root.view === "search"
                        clip: true
                        spacing: 6
                        model: root.results

                        delegate: Rectangle {
                            required property var modelData

                            width: ListView.view.width
                            height: 54
                            radius: 12
                            color: resArea.containsMouse ? "#37434b" : "#2a3238"

                            Column {
                                anchors.verticalCenter: parent.verticalCenter
                                anchors.left: parent.left
                                anchors.right: parent.right
                                anchors.margins: 12
                                spacing: 2

                                Text {
                                    width: parent.width
                                    text: modelData.name
                                    color: "#e0e0e0"
                                    font.pixelSize: 14
                                    elide: Text.ElideRight
                                }

                                Text {
                                    text: modelData.eps + " episodes" + (modelData.year > 0 ? " · " + modelData.year : "")
                                    color: "#8a949b"
                                    font.pixelSize: 11
                                }
                            }

                            MouseArea {
                                id: resArea

                                anchors.fill: parent
                                hoverEnabled: true
                                onClicked: root.openAnime(modelData)
                            }
                        }
                    }

                    // Episode grid
                    GridView {
                        id: grid

                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        visible: root.view === "episodes"
                        clip: true
                        cellWidth: Math.floor(width / 6)
                        cellHeight: 44
                        model: root.episodes

                        delegate: Item {
                            required property var modelData

                            width: grid.cellWidth
                            height: grid.cellHeight

                            Rectangle {
                                anchors.fill: parent
                                anchors.margins: 3
                                radius: 8
                                color: modelData === root.playingEp ? "#4f7cff" : (epArea.containsMouse ? "#37434b" : "#2a3238")

                                Text {
                                    anchors.centerIn: parent
                                    text: modelData
                                    color: "#e0e0e0"
                                    font.pixelSize: 13
                                }

                                MouseArea {
                                    id: epArea

                                    anchors.fill: parent
                                    hoverEnabled: true
                                    onClicked: root.play(modelData)
                                }
                            }
                        }
                    }

                    // Status line
                    Text {
                        Layout.fillWidth: true
                        text: root.playingEp !== "" ? "Playing episode " + root.playingEp + "…"
                            : root.loading ? "Loading…"
                            : root.message !== "" ? root.message
                            : (root.view === "search" && root.results.length === 0 ? "Type a name and press Enter" : "")
                        color: root.playingEp !== "" || root.loading ? "#8ab4f8" : (root.message !== "" ? "#f2b8b5" : "#8a949b")
                        font.pixelSize: 12
                        elide: Text.ElideRight
                        visible: text !== ""
                    }
                }
            }
        }
    }
}
