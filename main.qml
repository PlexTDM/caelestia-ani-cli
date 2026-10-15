// Ani Watch - search anime, pick a show, pick an episode (sub only, best quality).
// Requires: ani-cli (and its deps: curl, fzf, botan), mpv.
//
// Toggle the window with:  caelestia shell aniwatch toggle
// (bind that command in Nexus -> Shortcuts -> add a command shortcut)
//
// How it works:
//  - Search + episode lists: the same GraphQL calls ani-cli makes, via curl.
//    The API address, referer and user-agent are read from your installed
//    ani-cli script at startup, so they follow ani-cli updates.
//  - Playback: handed to ani-cli (`-S <result number> -e <episode> -q best`),
//    which handles stream resolution and launches mpv. Sub mode is forced.
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Scope {
    id: root

    // ---- state -----------------------------------------------------------
    property bool open: false
    property string view: "search"       // "search" | "episodes"
    property string query: ""
    property var results: []             // [{ id, name, eps, year, index }]
    property var episodes: []            // ["1", "2", ...] ascending
    property string playQuery: ""        // query that produced `results`
    property string showName: ""
    property int showIndex: 0            // 1-based position, what ani-cli -S expects
    property string status: ""
    property bool busy: false
    property bool playing: false

    // Filled from the installed ani-cli at startup (defaults match ani-cli 4.15).
    property string apiUrl: "https://api.mkissa.net"
    property string refererUrl: "https://mkissa.to"
    property string userAgent: "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:150.0) Gecko/20100101 Firefox/150.0"

    readonly property string searchGql: "query( $search: SearchInput $limit: Int $page: Int $translationType: VaildTranslationTypeEnumType $countryOrigin: VaildCountryOriginEnumType ) { shows( search: $search limit: $limit page: $page translationType: $translationType countryOrigin: $countryOrigin ) { edges { _id name availableEpisodes airedStart __typename } }}"
    readonly property string episodesGql: "query ($showId: String!) { show( _id: $showId ) { _id availableEpisodesDetail }}"
    readonly property string cfgScript: `f=$(command -v ani-cli) || exit 1; for v in allanime_api allanime_refr agent; do grep -m1 "^$v=" "$f" | cut -d'"' -f2; done`

    Component.onCompleted: cfgProc.running = true

    // ---- helpers ---------------------------------------------------------
    function curlPost(body) {
        return ["curl", "-s", "-m", "20",
                "-e", root.refererUrl, "-A", root.userAgent,
                "-H", "Content-Type: application/json",
                "-X", "POST", root.apiUrl + "/api",
                "--data", JSON.stringify(body)];
    }

    function startSearch() {
        const q = root.query.trim();
        if (q === "") {
            root.results = [];
            root.status = "";
            root.busy = false;
            return;
        }
        if (searchProc.running)
            return;   // onExited re-checks the query and restarts if it changed
        searchProc.sentQuery = q;
        // ani-cli turns spaces into "+" before searching; do the same so the
        // result order (and therefore the -S index) matches.
        searchProc.command = root.curlPost({
            variables: {
                search: { allowAdult: false, allowUnknown: false, query: q.replace(/\s+/g, "+") },
                limit: 40,
                page: 1,
                translationType: "sub",
                countryOrigin: "ALL"
            },
            query: root.searchGql
        });
        root.busy = true;
        root.status = "Searching...";
        searchProc.running = true;
    }

    function parseResults(text, q) {
        try {
            const edges = JSON.parse(text).data.shows.edges;
            const out = [];
            for (const e of edges) {
                const eps = e.availableEpisodes ? Number(e.availableEpisodes.sub) : 0;
                if (!(eps >= 1))
                    continue;   // sub only: skip shows with no sub episodes (same filter as ani-cli)
                out.push({
                    id: e._id,
                    name: e.name,
                    eps: eps,
                    year: (e.airedStart && e.airedStart.year) ? e.airedStart.year : 0,
                    index: out.length + 1
                });
            }
            root.results = out;
            root.playQuery = q;
            root.status = out.length === 0 ? "No sub results" : "";
        } catch (err) {
            root.status = "Unexpected API response - try updating ani-cli (ani-cli -U)";
        }
    }

    function pickShow(item) {
        if (episodesProc.running)
            return;
        root.showName = item.name;
        root.showIndex = item.index;
        root.episodes = [];
        root.view = "episodes";
        root.busy = true;
        root.status = "Loading episodes...";
        episodesProc.command = root.curlPost({ variables: { showId: item.id }, query: root.episodesGql });
        episodesProc.running = true;
    }

    function parseEpisodes(text) {
        try {
            const detail = JSON.parse(text).data.show.availableEpisodesDetail;
            const list = (detail.sub || []).slice();
            list.sort((a, b) => parseFloat(a) - parseFloat(b));
            root.episodes = list;
            root.status = list.length === 0 ? "No sub episodes found" : "";
        } catch (err) {
            root.status = "Unexpected API response - try updating ani-cli (ani-cli -U)";
        }
    }

    function play(ep) {
        if (playProc.running) {
            root.status = "Something is already playing - close mpv first";
            return;
        }
        // `env` sets sub mode, best quality and a TERM so ani-cli's tput calls stay quiet.
        // --exit-after-play skips ani-cli's interactive "next/replay" menu.
        playProc.command = ["env", "ANI_CLI_MODE=sub", "ANI_CLI_QUALITY=best", "TERM=xterm",
                            "ani-cli", "--exit-after-play",
                            "-S", String(root.showIndex),
                            "-e", String(ep),
                            "-q", "best",
                            root.playQuery];
        root.playing = true;
        root.status = "Starting episode " + ep + "...";
        playProc.running = true;
    }

    function back() {
        root.view = "search";
        root.status = "";
    }

    // ---- processes -------------------------------------------------------
    Process {
        id: cfgProc

        command: ["sh", "-c", root.cfgScript]
        stdout: StdioCollector { id: cfgOut }

        onExited: (code) => {
            if (code !== 0) {
                root.status = "ani-cli not found in the shell's PATH";
                return;
            }
            const l = cfgOut.text.split("\n");
            if (l[0]) root.apiUrl = l[0];
            if (l[1]) root.refererUrl = l[1];
            if (l[2]) root.userAgent = l[2];
        }
    }

    Process {
        id: searchProc

        property string sentQuery: ""

        stdout: StdioCollector { id: searchOut }

        onExited: (code) => {
            root.busy = false;
            if (root.query.trim() !== searchProc.sentQuery) {
                root.startSearch();   // query changed while we were waiting
                return;
            }
            if (code !== 0) {
                root.status = "Couldn't reach the anime API (curl exit " + code + ")";
                return;
            }
            root.parseResults(searchOut.text, searchProc.sentQuery);
        }
    }

    Process {
        id: episodesProc

        stdout: StdioCollector { id: episodesOut }

        onExited: (code) => {
            root.busy = false;
            if (code !== 0) {
                root.status = "Couldn't load episodes (curl exit " + code + ")";
                return;
            }
            root.parseEpisodes(episodesOut.text);
        }
    }

    Process {
        id: playProc

        stderr: StdioCollector { id: playErr }

        onExited: (code) => {
            root.playing = false;
            if (code === 0) {
                root.status = "";
                return;
            }
            const lines = playErr.text.replace(/\x1b\[[0-9;?]*[A-Za-z]/g, "").split("\n")
                .map(s => s.trim()).filter(s => s !== "");
            root.status = lines.length > 0 ? lines[lines.length - 1] : "ani-cli exited with code " + code;
        }
    }

    Timer {
        id: debounce

        interval: 450
        onTriggered: root.startSearch()
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

    // ---- UI --------------------------------------------------------------
    LazyLoader {
        active: root.open

        PanelWindow {
            implicitWidth: 560
            implicitHeight: 560
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
                    anchors.margins: 14
                    spacing: 10

                    // single search bar
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 8

                        Button {
                            visible: root.view === "episodes"
                            text: "\u2190"
                            onClicked: root.back()
                        }

                        TextField {
                            id: search

                            Layout.fillWidth: true
                            text: root.query
                            placeholderText: "Search anime..."
                            color: "#e0e0e0"
                            placeholderTextColor: "#8a949b"
                            font.pixelSize: 15
                            leftPadding: 12
                            background: Rectangle {
                                radius: 10
                                color: "#2a3035"
                            }
                            Component.onCompleted: forceActiveFocus()
                            onTextEdited: {
                                root.query = text;
                                root.view = "search";
                                debounce.restart();
                            }
                            onAccepted: {
                                debounce.stop();
                                root.startSearch();
                            }
                            Keys.onEscapePressed: {
                                if (root.view === "episodes")
                                    root.back();
                                else
                                    root.open = false;
                            }
                        }

                        Button {
                            text: "\u2715"
                            onClicked: root.open = false
                        }
                    }

                    Text {
                        Layout.fillWidth: true
                        visible: root.status !== ""
                        text: root.status
                        color: root.busy || root.playing ? "#9fb4c0" : "#f2b8b5"
                        font.pixelSize: 12
                        elide: Text.ElideRight
                    }

                    // step 1: results
                    ListView {
                        id: resultList

                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        visible: root.view === "search"
                        clip: true
                        spacing: 6
                        model: root.results
                        boundsBehavior: Flickable.StopAtBounds
                        ScrollBar.vertical: ScrollBar {}

                        delegate: Rectangle {
                            required property var modelData

                            width: resultList.width
                            height: 54
                            radius: 10
                            color: rowMouse.containsMouse ? "#323b42" : "#2a3035"

                            Column {
                                anchors.verticalCenter: parent.verticalCenter
                                anchors.left: parent.left
                                anchors.leftMargin: 12
                                width: parent.width - 24
                                spacing: 2

                                Text {
                                    width: parent.width
                                    text: modelData.name
                                    color: "#e0e0e0"
                                    font.pixelSize: 14
                                    elide: Text.ElideRight
                                }

                                Text {
                                    text: modelData.eps + " sub episodes" + (modelData.year ? "  \u00b7  " + modelData.year : "")
                                    color: "#8a949b"
                                    font.pixelSize: 11
                                }
                            }

                            MouseArea {
                                id: rowMouse

                                anchors.fill: parent
                                hoverEnabled: true
                                onClicked: root.pickShow(modelData)
                            }
                        }
                    }

                    // step 2: episodes
                    ColumnLayout {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        visible: root.view === "episodes"
                        spacing: 8

                        Text {
                            Layout.fillWidth: true
                            text: root.showName
                            color: "#e0e0e0"
                            font.pixelSize: 16
                            font.bold: true
                            elide: Text.ElideRight
                        }

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 10

                            Text {
                                text: "Sub \u00b7 best quality"
                                color: "#8a949b"
                                font.pixelSize: 12
                            }

                            Item {
                                Layout.fillWidth: true
                            }

                            Button {
                                visible: root.episodes.length > 0
                                text: "Play latest (ep " + root.episodes[root.episodes.length - 1] + ")"
                                onClicked: root.play(root.episodes[root.episodes.length - 1])
                            }
                        }

                        GridView {
                            id: epGrid

                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            clip: true
                            cellWidth: 70
                            cellHeight: 46
                            model: root.episodes
                            boundsBehavior: Flickable.StopAtBounds
                            ScrollBar.vertical: ScrollBar {}

                            delegate: Item {
                                required property var modelData

                                width: epGrid.cellWidth
                                height: epGrid.cellHeight

                                Rectangle {
                                    anchors.fill: parent
                                    anchors.margins: 3
                                    radius: 8
                                    color: epMouse.containsMouse ? "#3d6a8a" : "#2a3035"

                                    Text {
                                        anchors.centerIn: parent
                                        text: modelData
                                        color: "#e0e0e0"
                                        font.pixelSize: 14
                                    }

                                    MouseArea {
                                        id: epMouse

                                        anchors.fill: parent
                                        hoverEnabled: true
                                        onClicked: root.play(modelData)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
