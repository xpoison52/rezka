import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Window
import QtMultimedia

ApplicationWindow {
    id: root
    width: Screen.width
    height: Screen.height
    visibility: Window.FullScreen
    visible: true
    title: "Rezka Native TV"
    color: "#111111"

    property bool loggedIn: false
    property var historyItems: []
    property string listTitle: "Последние просмотренные"
    property var selectedListItem: ({})
    property var selectedMovie: ({})
    property var currentStream: ({})
    property int selectedSeasonIndex: 0
    property int selectedEpisodeIndex: 0
    property int selectedTranslatorIndex: 0
    property string selectedQuality: "Auto"
    property var subtitleCues: []
    property string activeSubtitleText: ""
    property string loadingMessage: ""
    property bool playerControlsVisible: true
    property bool streamLoading: loadingMessage === "Получаем видеопоток..."
    // Не показывать «Буферизация», если данные уже в буфере (иначе после паузы на macOS
    // часто залипает BufferingMedia/LoadingMedia до следующего seek).
    property bool bufferingVisible: streamLoading || (mediaPlayer.playbackState === MediaPlayer.PlayingState
        && (mediaPlayer.mediaStatus === MediaPlayer.LoadingMedia || mediaPlayer.mediaStatus === MediaPlayer.BufferingMedia)
        && mediaPlayer.bufferProgress < 0.99)
    property int pendingSeekPosition: 0
    property int pendingSeekAttempts: 0
    property int resumeSeekPosition: 0
    property int lastProgressPosition: 0
    property int sourceNonce: 0
    property bool qualitySwitchInFlight: false
    property bool qualitySwitchResumePlay: true
    property int selectedSubtitleIndex: 0
    property int subtitleFontSize: 30
    property int subtitleSafeBottomGap: 18
    property int modalSeasonIndex: 0
    property int modalEpisodeIndex: 0
    property bool watchSetupFlow: false
    property var qualityOptions: ["Auto", "360p", "480p", "720p", "1080p", "1080p Ultra"]
    property var appUpdate: ({ status: "idle", message: "", commitsBehind: 0, localShort: "", remoteShort: "", channel: "github" })
    property string companionLoginPageUrl: ""
    property string companionSearchPageUrl: ""
    property string companionLoginQr: ""
    property string companionSearchQr: ""

    property int hkLeft: Qt.Key_Left
    property int hkRight: Qt.Key_Right
    property int hkUp: Qt.Key_Up
    property int hkDown: Qt.Key_Down
    property int hkBack: Qt.Key_Escape
    property int hkConfirm: Qt.Key_Space
    property bool tvHotkeysWizardVisible: false
    property int tvWizardStepIndex: 0
    property string tvHotkeysWizardError: ""
    property var tvWizardPending: ({})

    component TvButton: Button {
        id: tvButton
        property bool tvPassNavigationKeys: false
        focusPolicy: tvPassNavigationKeys ? Qt.NoFocus : Qt.TabFocus
        font.pixelSize: 20
        padding: 10
        leftPadding: 14
        rightPadding: 14

        contentItem: Text {
            text: tvButton.text
            color: tvButton.enabled ? "white" : "#777777"
            font: tvButton.font
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            elide: Text.ElideRight
        }

        background: Rectangle {
            radius: 8
            color: tvButton.activeFocus ? "#3d6fb6" : tvButton.down ? "#264d82" : tvButton.hovered ? "#343434" : "#242424"
            border.width: tvButton.activeFocus ? 3 : 1
            border.color: tvButton.activeFocus ? "#b7d7ff" : "#3c3c3c"
        }

        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function (event) {
            if (!tvButton.activeFocus || !tvButton.enabled)
                return
            if (!root.isTvActivateButton(event))
                return
            event.accepted = true
            tvButton.clicked()
        }
    }

    component TvComboBox: ComboBox {
        id: tvCombo
        font.pixelSize: 18

        delegate: ItemDelegate {
            width: ListView.view ? ListView.view.width : tvCombo.width
            highlighted: tvCombo.highlightedIndex === index
            contentItem: Text {
                text: tvCombo.textRole ? (modelData[tvCombo.textRole] || "") : modelData
                color: highlighted ? "#111111" : "white"
                font.pixelSize: tvCombo.font.pixelSize
                elide: Text.ElideRight
                verticalAlignment: Text.AlignVCenter
            }
            background: Rectangle {
                color: highlighted ? "#8ec7ff" : "#242424"
                radius: 8
            }
        }

        indicator: Text {
            text: "v"
            color: tvCombo.activeFocus ? "#d9ecff" : "white"
            font.pixelSize: 18
            verticalAlignment: Text.AlignVCenter
            horizontalAlignment: Text.AlignHCenter
        }

        contentItem: Text {
            leftPadding: 12
            rightPadding: 28
            text: tvCombo.displayText
            color: "white"
            font: tvCombo.font
            elide: Text.ElideRight
            verticalAlignment: Text.AlignVCenter
        }

        background: Rectangle {
            radius: 8
            color: "#202020"
            border.width: tvCombo.activeFocus ? 3 : 1
            border.color: tvCombo.activeFocus ? "#8ec7ff" : "#3c3c3c"
        }

        popup: Popup {
            y: tvCombo.height + 4
            width: tvCombo.width
            implicitHeight: contentItem.implicitHeight + 8
            padding: 4
            contentItem: ListView {
                clip: true
                implicitHeight: contentHeight
                model: tvCombo.popup.visible ? tvCombo.delegateModel : null
                currentIndex: tvCombo.highlightedIndex
            }
            background: Rectangle {
                radius: 10
                color: "#1a1a1a"
                border.width: 2
                border.color: "#6fa8df"
            }
        }
    }

    function formatTime(ms) {
        if (!ms || ms <= 0)
            return "0:00"

        const total = Math.floor(ms / 1000)
        const hours = Math.floor(total / 3600)
        const minutes = Math.floor((total % 3600) / 60)
        const seconds = total % 60
        const mm = hours > 0 && minutes < 10 ? "0" + minutes : String(minutes)
        const ss = seconds < 10 ? "0" + seconds : String(seconds)
        return hours > 0 ? hours + ":" + mm + ":" + ss : minutes + ":" + ss
    }

    function itemResumePosition(item) {
        const value = Number(item && item.resumePosition ? item.resumePosition : 0)
        return isNaN(value) ? 0 : value
    }

    function itemHasContinue(item) {
        if (!item)
            return false
        return itemResumePosition(item) > 0 || !!item.resumeSeason || !!item.resumeEpisode || String(item.play_url || "").indexOf("#continue") >= 0
    }

    function resumeText(item) {
        if (itemResumePosition(item) > 0)
            return "Продолжить " + formatTime(itemResumePosition(item))
        if (item && item.resumeSeason && item.resumeEpisode)
            return "Продолжить: " + item.resumeSeason + " сезон " + item.resumeEpisode + " серия"
        return "Продолжить"
    }

    function indexByField(items, field, value) {
        const wanted = String(value || "")
        if (!items || !wanted)
            return -1
        for (let i = 0; i < items.length; i++) {
            if (String(items[i][field] || "") === wanted)
                return i
        }
        return -1
    }

    function applyResumeSelection() {
        if (!selectedMovie.isSeries || !selectedListItem)
            return

        const seasons = seasonsModel()
        const seasonIndex = indexByField(seasons, "season", selectedListItem.resumeSeason)
        if (seasonIndex >= 0)
            selectedSeasonIndex = seasonIndex

        const episodes = episodesModel()
        const episodeIndex = indexByField(episodes, "episode", selectedListItem.resumeEpisode)
        if (episodeIndex >= 0)
            selectedEpisodeIndex = episodeIndex
    }

    function openListItem(item) {
        if (!item)
            return

        selectedListItem = item
        backend.loadDetails(item.url)
    }

    function seasonsModel() {
        return selectedMovie.episodesInfo || []
    }

    function currentSeason() {
        const seasons = seasonsModel()
        if (!seasons || seasons.length === 0)
            return null
        if (selectedSeasonIndex < 0 || selectedSeasonIndex >= seasons.length)
            selectedSeasonIndex = 0
        return seasons[selectedSeasonIndex]
    }

    function episodesModel() {
        const season = currentSeason()
        return season && season.episodes ? season.episodes : []
    }

    function currentEpisode() {
        const episodes = episodesModel()
        if (!episodes || episodes.length === 0)
            return null
        if (selectedEpisodeIndex < 0 || selectedEpisodeIndex >= episodes.length)
            selectedEpisodeIndex = 0
        return episodes[selectedEpisodeIndex]
    }

    function translatorsModel() {
        const ep = currentEpisode()
        if (ep && ep.translations)
            return ep.translations

        const result = []
        const translators = selectedMovie.translators || {}
        for (const id in translators) {
            result.push({
                translator_id: id,
                translator_name: translators[id].name || id,
                premium: translators[id].premium || false
            })
        }
        return result
    }

    function translatorIndexById(translatorId) {
        const translators = translatorsModel()
        const wanted = String(translatorId || "")
        for (let i = 0; i < translators.length; i++) {
            if (String(translators[i].translator_id || "") === wanted)
                return i
        }
        return translators.length > 0 ? 0 : -1
    }

    function setEpisodeIndex(index) {
        const translatorId = currentTranslatorId()
        selectedEpisodeIndex = index
        const nextTranslatorIndex = translatorIndexById(translatorId)
        selectedTranslatorIndex = nextTranslatorIndex >= 0 ? nextTranslatorIndex : 0
    }

    function setTranslatorIndex(index, restartInPlayer) {
        selectedTranslatorIndex = Math.max(0, index)
        if (restartInPlayer && stack.currentIndex === 3)
            startWatchAt(mediaPlayer.position)
    }

    function setSeasonIndex(index) {
        const translatorId = currentTranslatorId()
        selectedSeasonIndex = index
        selectedEpisodeIndex = 0
        const nextTranslatorIndex = translatorIndexById(translatorId)
        selectedTranslatorIndex = nextTranslatorIndex >= 0 ? nextTranslatorIndex : 0
    }

    function currentTranslatorId() {
        const translators = translatorsModel()
        if (!translators || translators.length === 0)
            return ""

        if (selectedTranslatorIndex < 0 || selectedTranslatorIndex >= translators.length)
            selectedTranslatorIndex = 0

        return String(translators[selectedTranslatorIndex].translator_id || "")
    }

    function currentTranslatorName() {
        const translators = translatorsModel()
        if (!translators || translators.length === 0)
            return ""

        if (selectedTranslatorIndex < 0 || selectedTranslatorIndex >= translators.length)
            return ""

        return String(translators[selectedTranslatorIndex].translator_name || "")
    }

    function ratingText() {
        if (!selectedMovie.rating || !selectedMovie.rating.value)
            return "Рейтинг не указан"

        let text = "Рейтинг: " + selectedMovie.rating.value
        if (selectedMovie.rating.votes)
            text += " (" + selectedMovie.rating.votes + ")"

        return text
    }

    function startWatchAt(positionMs) {
        const season = currentSeason()
        const episode = currentEpisode()

        const seasonId = season ? String(season.season) : ""
        const episodeId = episode ? String(episode.episode) : ""
        const translatorId = currentTranslatorId()

        resumeSeekPosition = Math.max(0, Number(positionMs || 0))
        backend.loadStream(seasonId, episodeId, selectedQuality, translatorId)
    }

    function startWatch() {
        startWatchAt(0)
    }

    function continueWatch() {
        applyResumeSelection()
        applyResumePreferences()
        startWatchAt(itemResumePosition(selectedListItem))
    }

    function applyResumePreferences() {
        if (!selectedListItem)
            return

        const resumeQuality = String(selectedListItem.resumeQuality || "")
        if (resumeQuality && qualityOptions.indexOf(resumeQuality) >= 0)
            selectedQuality = resumeQuality

        const resumeTranslatorId = String(selectedListItem.resumeTranslatorId || "")
        if (resumeTranslatorId) {
            const byId = translatorIndexById(resumeTranslatorId)
            if (byId >= 0) {
                selectedTranslatorIndex = byId
                return
            }
        }

        const wantedName = String(selectedListItem.resumeTranslatorName || "").toLowerCase()
        if (!wantedName)
            return

        const translators = translatorsModel()
        for (let i = 0; i < translators.length; i++) {
            const name = String(translators[i].translator_name || "").toLowerCase()
            if (name && (name.indexOf(wantedName) >= 0 || wantedName.indexOf(name) >= 0)) {
                selectedTranslatorIndex = i
                return
            }
        }
    }

    function startWatchSelectionFlow() {
        watchSetupFlow = true
        applyResumeSelection()
        applyResumePreferences()
        if (selectedMovie.isSeries) {
            modalSeasonIndex = selectedSeasonIndex
            modalEpisodeIndex = selectedEpisodeIndex
            seasonEpisodeModal.open()
            modalSeasonsList.currentIndex = modalSeasonIndex
            modalEpisodesList.currentIndex = modalEpisodeIndex
            modalSeasonsList.forceActiveFocus()
        } else {
            translatorModal.open()
            translatorList.forceActiveFocus()
        }
    }

    function canGoPreviousEpisode() {
        if (!selectedMovie.isSeries)
            return false

        if (selectedEpisodeIndex > 0)
            return true

        const seasons = seasonsModel()
        return selectedSeasonIndex > 0 && seasons[selectedSeasonIndex - 1] && seasons[selectedSeasonIndex - 1].episodes && seasons[selectedSeasonIndex - 1].episodes.length > 0
    }

    function canGoNextEpisode() {
        const episodes = episodesModel()
        if (!selectedMovie.isSeries)
            return false

        if (selectedEpisodeIndex >= 0 && selectedEpisodeIndex < episodes.length - 1)
            return true

        const seasons = seasonsModel()
        return selectedSeasonIndex < seasons.length - 1 && seasons[selectedSeasonIndex + 1] && seasons[selectedSeasonIndex + 1].episodes && seasons[selectedSeasonIndex + 1].episodes.length > 0
    }

    function playPreviousEpisode() {
        if (!canGoPreviousEpisode())
            return

        if (selectedEpisodeIndex > 0) {
            setEpisodeIndex(selectedEpisodeIndex - 1)
        } else {
            setSeasonIndex(selectedSeasonIndex - 1)
            const episodes = episodesModel()
            const nextIndex = Math.max(0, episodes.length - 1)
            setEpisodeIndex(nextIndex)
        }
        startWatchAt(0)
    }

    function playNextEpisode() {
        if (!canGoNextEpisode())
            return

        const episodes = episodesModel()
        if (selectedEpisodeIndex < episodes.length - 1) {
            setEpisodeIndex(selectedEpisodeIndex + 1)
        } else {
            setSeasonIndex(selectedSeasonIndex + 1)
            setEpisodeIndex(0)
        }
        startWatchAt(0)
    }

    function showPlayerControls() {
        playerControlsVisible = true
        controlsHideTimer.restart()
    }

    function playerTopEpisodeLine() {
        if (!selectedMovie.isSeries)
            return ""

        const streamSeason = currentStream && currentStream.season !== undefined && currentStream.season !== null ? String(currentStream.season) : ""
        const streamEpisode = currentStream && currentStream.episode !== undefined && currentStream.episode !== null ? String(currentStream.episode) : ""
        const season = streamSeason || (currentSeason() ? String(currentSeason().season) : "")
        const episode = streamEpisode || (currentEpisode() ? String(currentEpisode().episode) : "")

        if (!season && !episode)
            return ""

        const seasonObj = currentSeason()
        const episodeObj = currentEpisode()
        const seasonText = seasonObj && seasonObj.season_text ? seasonObj.season_text : ("Сезон " + season)
        const episodeText = episodeObj && episodeObj.episode_text ? episodeObj.episode_text : ("Серия " + episode)
        return seasonText + " · " + episodeText
    }

    function seekBy(deltaMs) {
        if (mediaPlayer.duration <= 0)
            return

        const nextPosition = Math.max(0, Math.min(mediaPlayer.duration, mediaPlayer.position + deltaMs))
        mediaPlayer.setPosition(nextPosition)
        updateSubtitleText()
        showPlayerControls()
    }

    function isLinuxTvOkEvent(event) {
        return event.key === Qt.Key_Yes || event.nativeScanCode === 352
    }

    function isTvActivateButton(event) {
        if (!event)
            return false
        // ОК: назначаемая клавиша (hkConfirm) + аппаратный KEY_OK на пультах (часто Qt.Key_Yes / scancode 352).
        if (event.key === root.hkBack || event.key === Qt.Key_Escape)
            return false
        if (isLinuxTvOkEvent(event))
            return true
        return event.key === root.hkConfirm
    }

    function applyTvHotkeysFromJsonText(jsonText) {
        var raw = (jsonText || "").trim()
        if (!raw || raw === "{}") {
            hkLeft = Qt.Key_Left
            hkRight = Qt.Key_Right
            hkUp = Qt.Key_Up
            hkDown = Qt.Key_Down
            hkBack = Qt.Key_Escape
            hkConfirm = Qt.Key_Space
            return
        }
        try {
            var o = JSON.parse(raw)
            hkLeft = o.left !== undefined ? o.left : Qt.Key_Left
            hkRight = o.right !== undefined ? o.right : Qt.Key_Right
            hkUp = o.up !== undefined ? o.up : Qt.Key_Up
            hkDown = o.down !== undefined ? o.down : Qt.Key_Down
            hkBack = o.back !== undefined ? o.back : Qt.Key_Escape
            hkConfirm = o.confirm !== undefined ? o.confirm : Qt.Key_Space
        } catch (e) {
        }
    }

    function reloadTvHotkeysFromBackend() {
        applyTvHotkeysFromJsonText(backend.readTvHotkeysJson())
    }

    function tvLoginPageBack() {
        backend.quit()
    }

    function tvContinueToolbarBackFromSearch() {
        if (!loggedIn) {
            stack.currentIndex = 0
            email.forceActiveFocus()
        } else {
            continueTabButton.forceActiveFocus()
        }
    }

    function loginFormNavigateHorizontal(goRight) {
        var cur = root.activeFocusItem
        if (cur !== email && cur !== password && cur !== loginButton && cur !== updateCheckLoginButton)
            return false
        if (goRight) {
            if (cur === email)
                password.forceActiveFocus()
            else if (cur === password)
                loginButton.forceActiveFocus()
            else if (cur === loginButton)
                updateCheckLoginButton.forceActiveFocus()
            else if (cur === updateCheckLoginButton)
                email.forceActiveFocus()
            else
                return false
        } else {
            if (cur === email)
                loginButton.forceActiveFocus()
            else if (cur === password)
                email.forceActiveFocus()
            else if (cur === loginButton)
                password.forceActiveFocus()
            else if (cur === updateCheckLoginButton)
                password.forceActiveFocus()
            else
                return false
        }
        return true
    }

    function continueToolbarNavigateHorizontal(goRight) {
        var cur = root.activeFocusItem
        if (cur !== continueTabButton && cur !== searchField && cur !== searchButton && cur !== updateCheckToolbarButton && cur !== quitButton)
            return false
        if (goRight) {
            if (cur === continueTabButton)
                searchField.forceActiveFocus()
            else if (cur === searchField)
                searchButton.forceActiveFocus()
            else if (cur === searchButton)
                updateCheckToolbarButton.forceActiveFocus()
            else if (cur === updateCheckToolbarButton)
                quitButton.forceActiveFocus()
            else if (cur === quitButton)
                continueTabButton.forceActiveFocus()
            else
                return false
        } else {
            if (cur === continueTabButton)
                quitButton.forceActiveFocus()
            else if (cur === searchField)
                continueTabButton.forceActiveFocus()
            else if (cur === searchButton)
                searchField.forceActiveFocus()
            else if (cur === updateCheckToolbarButton)
                searchButton.forceActiveFocus()
            else if (cur === quitButton)
                updateCheckToolbarButton.forceActiveFocus()
            else
                return false
        }
        return true
    }

    function tvWizardKeyNames() {
        return ["left", "right", "up", "down", "back", "confirm"]
    }

    function tvWizardStepTitleRu() {
        var titles = [
            "Стрелка влево",
            "Стрелка вправо",
            "Стрелка вверх",
            "Стрелка вниз",
            "Назад",
            "ОК (выбор в списках, Play на плеере)"
        ]
        return titles[tvWizardStepIndex] || ""
    }

    function tvWizardApplyKey(event) {
        var k = event.key
        if (k === Qt.Key_unknown || k === Qt.Key_Shift || k === Qt.Key_Control || k === Qt.Key_Alt || k === Qt.Key_Meta || k === Qt.Key_AltGr)
            return false
        var names = tvWizardKeyNames()
        if (tvWizardStepIndex < 0 || tvWizardStepIndex >= names.length)
            return false
        // Пробел зарезервирован для шага «ОК»; на шагах навигации не принимаем.
        if (k === Qt.Key_Space && tvWizardStepIndex < names.length - 1) {
            tvHotkeysWizardError = "Пробел назначается на последнем шаге (ОК). Сейчас выберите другую клавишу."
            event.accepted = true
            return true
        }
        var n = names[tvWizardStepIndex]
        var copy = Object.assign({}, tvWizardPending)
        copy[n] = k
        tvWizardPending = copy
        event.accepted = true
        tvHotkeysWizardError = ""
        if (tvWizardStepIndex < names.length - 1) {
            tvWizardStepIndex++
        } else {
            if (!backend.saveTvHotkeysJson(JSON.stringify(copy))) {
                tvHotkeysWizardError = "Все шесть клавиш должны быть разными. Начните сначала."
                tvWizardStepIndex = 0
                tvWizardPending = ({})
            } else {
                root.reloadTvHotkeysFromBackend()
                tvHotkeysWizardVisible = false
                tvWizardStepIndex = 0
                tvWizardPending = ({})
                Qt.callLater(function () {
                    if (stack.currentIndex === 1)
                        grid.forceActiveFocus()
                    else if (stack.currentIndex === 0)
                        email.forceActiveFocus()
                    else if (stack.currentIndex === 2)
                        watchButton.forceActiveFocus()
                    else if (stack.currentIndex === 3)
                        playerPage.forceActiveFocus()
                })
            }
        }
        return true
    }

    function progressRatio() {
        if (mediaPlayer.duration <= 0)
            return 0
        return Math.max(0, Math.min(1, mediaPlayer.position / mediaPlayer.duration))
    }

    function subtitleOptions() {
        const result = [{ title: "Субтитры: выкл", url: "" }]
        const subtitles = currentStream.subtitles || {}
        for (const id in subtitles) {
            result.push({
                title: subtitles[id].title || id,
                url: subtitles[id].url || ""
            })
        }
        return result
    }

    function selectedSubtitleTitle() {
        const options = subtitleOptions()
        if (selectedSubtitleIndex >= 0 && selectedSubtitleIndex < options.length)
            return options[selectedSubtitleIndex].title
        return "Субтитры: выкл"
    }

    function selectSubtitle(index) {
        const options = subtitleOptions()
        const item = options[index]
        selectedSubtitleIndex = Math.max(0, index)
        subtitleCues = []
        activeSubtitleText = ""
        if (item && item.url)
            backend.loadSubtitles(item.url)
    }

    function enableRussianSubtitlesForOriginal() {
        const translatorName = currentTranslatorName().toLowerCase()
        if (translatorName.indexOf("ориг") < 0) {
            selectedSubtitleIndex = 0
            return
        }

        const options = subtitleOptions()
        for (let i = 1; i < options.length; i++) {
            const title = String(options[i].title || "").toLowerCase()
            if (title.indexOf("рус") >= 0 || title.indexOf("rus") >= 0) {
                selectSubtitle(i)
                return
            }
        }

        selectedSubtitleIndex = 0
    }

    function updateSubtitleText() {
        if (!subtitleCues || subtitleCues.length === 0) {
            activeSubtitleText = ""
            return
        }

        const position = mediaPlayer.position
        for (let i = 0; i < subtitleCues.length; i++) {
            const cue = subtitleCues[i]
            if (position >= cue.start && position <= cue.end) {
                activeSubtitleText = cue.text
                return
            }
        }
        activeSubtitleText = ""
    }

    function streamUrlForQuality(quality) {
        const videos = currentStream.videos || {}
        if (videos[quality] && videos[quality].length > 0)
            return videos[quality][0]

        for (const key in videos) {
            if (key.indexOf(quality) >= 0 && videos[key].length > 0)
                return videos[key][0]
        }
        return ""
    }

    function mediaSourceUrlString(src) {
        return src ? String(src) : ""
    }

    function switchStreamQuality(quality) {
        const url = streamUrlForQuality(quality)
        if (!url || mediaSourceUrlString(mediaPlayer.source) === String(url))
            return

        selectedQuality = quality
        pendingSeekPosition = Math.max(0, mediaPlayer.position)
        pendingSeekAttempts = 0
        qualitySwitchResumePlay = (mediaPlayer.playbackState === MediaPlayer.PlayingState)
        qualitySwitchInFlight = true
        sourceNonce++
        // Не вызывать play() сразу: поток начинает с 0 и успевает сбросить pending seek.
        mediaPlayer.pause()
        mediaPlayer.source = url
        showPlayerControls()
    }

    Connections {
        target: backend

        function onLoginChanged(ok) {
            loggedIn = ok
            if (ok) {
                stack.currentIndex = 1
                grid.forceActiveFocus()
            }
        }

        function onHistoryChanged(json) {
            historyItems = JSON.parse(json)
        }

        function onDetailsChanged(json) {
            mediaPlayer.stop()
            currentStream = ({})
            subtitleCues = []
            activeSubtitleText = ""
            selectedMovie = JSON.parse(json)
            selectedSeasonIndex = 0
            selectedEpisodeIndex = 0
            stack.currentIndex = 2
            applyResumeSelection()
            applyResumePreferences()
            if (itemHasContinue(selectedListItem))
                continueWatchButton.forceActiveFocus()
            else
                watchButton.forceActiveFocus()
        }

        function onEpisodesChanged(json) {
            const data = JSON.parse(json)
            if (data.url !== selectedMovie.url)
                return

            const translatorId = currentTranslatorId()
            selectedMovie = Object.assign({}, selectedMovie, {
                episodesInfo: data.episodesInfo || [],
                seriesInfo: data.seriesInfo || {},
                episodesLoading: false
            })
            selectedSeasonIndex = 0
            selectedEpisodeIndex = 0
            applyResumeSelection()
            const nextTranslatorIndex = translatorIndexById(translatorId)
            selectedTranslatorIndex = nextTranslatorIndex >= 0 ? nextTranslatorIndex : 0
        }

        function onStreamChanged(json) {
            currentStream = JSON.parse(json)
            subtitleCues = []
            activeSubtitleText = ""
            selectedSubtitleIndex = 0

            if (currentStream.availableQualities && currentStream.availableQualities.length > 0) {
                selectedQuality = currentStream.quality || currentStream.availableQualities[0]
            }

            mediaPlayer.stop()
            mediaPlayer.source = ""
            qualitySwitchInFlight = false
            stack.currentIndex = 3
            playerPage.forceActiveFocus()
            showPlayerControls()
            sourceNonce++
            pendingSeekPosition = resumeSeekPosition
            pendingSeekAttempts = 0
            resumeSeekPosition = 0
            mediaPlayer.source = currentStream.videoUrl || ""
            mediaPlayer.play()
            lastProgressPosition = 0
            backend.saveWatchProgress(0, 0, 0)
            enableRussianSubtitlesForOriginal()
        }

        function onErrorChanged(message) {
            errorText.text = message
            detailsErrorText.text = message
            playerErrorText.text = message
        }

        function onSubtitlesChanged(json) {
            subtitleCues = JSON.parse(json)
            updateSubtitleText()
        }

        function onLoadingChanged(message) {
            loadingMessage = message
        }

        function onCompanionSearchApplied(q) {
            listTitle = "Поиск: " + q
            searchField.text = q
            if (stack.currentIndex === 1)
                grid.forceActiveFocus()
        }

        function onAppUpdateChanged(json) {
            appUpdate = JSON.parse(json)
            const s = appUpdate.status
            if (s === "checking" || s === "behind" || s === "current" || s === "error" || s === "pulling" || s === "restarting")
                appUpdatePopup.open()
        }

        function onTvHotkeysChanged(json) {
            root.reloadTvHotkeysFromBackend()
        }

        function onCompanionLoginUrlChanged(u) {
            root.companionLoginPageUrl = u || ""
        }

        function onCompanionSearchUrlChanged(u) {
            root.companionSearchPageUrl = u || ""
        }

        function onCompanionLoginQrChanged(dataUrl) {
            root.companionLoginQr = dataUrl || ""
        }

        function onCompanionSearchQrChanged(dataUrl) {
            root.companionSearchQr = dataUrl || ""
        }
    }

    Popup {
        id: appUpdatePopup
        parent: Overlay.overlay
        x: Math.round((parent.width - width) / 2)
        y: Math.round((parent.height - height) / 2)
        width: Math.min(520, parent.width - 48)
        padding: 24
        modal: true
        focus: true
        closePolicy: (appUpdate.status === "pulling" || appUpdate.status === "restarting" || appUpdate.status === "checking")
                       ? Popup.NoAutoClose
                       : (Popup.CloseOnEscape | Popup.CloseOnPressOutside)

        onOpened: updatePopupFocusTimer.start()

        background: Rectangle {
            color: "#2a2a2a"
            radius: 12
            border.width: 1
            border.color: "#4a4a4a"
        }

        contentItem: FocusScope {
            id: updatePopupRoot
            focus: true
            width: appUpdatePopup.availableWidth
            implicitHeight: updatePopupColumn.implicitHeight

            ColumnLayout {
                id: updatePopupColumn
                width: parent.width
                spacing: 16

                Text {
                    Layout.fillWidth: true
                    wrapMode: Text.WordWrap
                    color: "white"
                    font.pixelSize: 22
                    font.bold: true
                    text: {
                        switch (appUpdate.status) {
                        case "checking":
                            return "Проверка обновлений…"
                        case "behind":
                            return "Доступно обновление"
                        case "current":
                            return "Обновления"
                        case "error":
                            return "Ошибка обновления"
                        case "pulling":
                            return "Установка"
                        case "restarting":
                            return "Перезапуск"
                        default:
                            return ""
                        }
                    }
                }

                Text {
                    Layout.fillWidth: true
                    wrapMode: Text.WordWrap
                    color: "#cccccc"
                    font.pixelSize: 17
                    visible: text.length > 0
                    text: {
                        let t = appUpdate.message || ""
                        if (appUpdate.status === "behind" && appUpdate.localShort && appUpdate.remoteShort) {
                            if (appUpdate.channel === "git")
                                t += "\nЛокально: " + appUpdate.localShort + " → сервер: " + appUpdate.remoteShort
                            else
                                t += "\nУ вас: " + appUpdate.localShort + " · на GitHub: " + appUpdate.remoteShort
                        }
                        return t
                    }
                }

                BusyIndicator {
                    Layout.alignment: Qt.AlignHCenter
                    visible: appUpdate.status === "checking" || appUpdate.status === "pulling" || appUpdate.status === "restarting"
                    running: visible
                }

                RowLayout {
                    Layout.fillWidth: true
                    visible: appUpdate.status === "behind"
                    spacing: 12

                    TvButton {
                        id: updateInstallBtn
                        text: appUpdate.channel === "git" ? "Установить и перезапустить" : "Открыть загрузку"
                        font.pixelSize: 18
                        Layout.fillWidth: true
                        KeyNavigation.right: updateLaterBtn
                        onClicked: {
                            appUpdatePopup.close()
                            backend.applyAppUpdateAndRestart()
                        }
                    }

                    TvButton {
                        id: updateLaterBtn
                        text: "Позже"
                        font.pixelSize: 18
                        KeyNavigation.left: updateInstallBtn
                        onClicked: appUpdatePopup.close()
                    }
                }

                TvButton {
                    id: updateOkBtn
                    Layout.fillWidth: true
                    visible: appUpdate.status === "current" || appUpdate.status === "error"
                    text: "OK"
                    font.pixelSize: 18
                    onClicked: appUpdatePopup.close()
                }
            }

            Keys.onPressed: function (event) {
                if (root.tvHotkeysWizardVisible && root.tvWizardApplyKey(event))
                    return
                var k = event.key
                var left = k === root.hkLeft || k === Qt.Key_Left
                var right = k === root.hkRight || k === Qt.Key_Right
                var up = k === root.hkUp || k === Qt.Key_Up
                var down = k === root.hkDown || k === Qt.Key_Down
                if (appUpdate.status === "behind" && (left || right || up || down)) {
                    var fi0 = root.activeFocusItem
                    if (fi0 === updateInstallBtn || fi0 === updateLaterBtn) {
                        if (fi0 === updateInstallBtn)
                            updateLaterBtn.forceActiveFocus()
                        else
                            updateInstallBtn.forceActiveFocus()
                        event.accepted = true
                        return
                    }
                }
                if (k === root.hkBack || k === Qt.Key_Escape) {
                    if (!(appUpdate.status === "pulling" || appUpdate.status === "restarting" || appUpdate.status === "checking")) {
                        event.accepted = true
                        appUpdatePopup.close()
                    }
                    return
                }
                if (root.isTvActivateButton(event)) {
                    var fi = root.activeFocusItem
                    if (fi && typeof fi.click === "function") {
                        event.accepted = true
                        fi.click()
                    }
                    return
                }
                if ((up || down) && (appUpdate.status === "current" || appUpdate.status === "error") && updateOkBtn.visible) {
                    updateOkBtn.forceActiveFocus()
                    event.accepted = true
                }
            }
        }
    }

    Timer {
        id: updatePopupFocusTimer
        interval: 0
        repeat: false
        onTriggered: {
            updatePopupRoot.forceActiveFocus()
            if (appUpdate.status === "behind")
                updateInstallBtn.forceActiveFocus()
            else if (appUpdate.status === "current" || appUpdate.status === "error")
                updateOkBtn.forceActiveFocus()
        }
    }

    Timer {
        id: refocusGridTimer
        interval: 0
        repeat: false
        onTriggered: {
            if (stack.currentIndex === 1)
                grid.forceActiveFocus()
        }
    }

    StackLayout {
        id: stack
        anchors.fill: parent
        currentIndex: 0

        onCurrentIndexChanged: {
            if (loggedIn && currentIndex === 0) {
                currentIndex = 1
                refocusGridTimer.start()
            }
            if (currentIndex === 0 || currentIndex === 1)
                backend.startCompanionServer()
        }

        Item {
            id: loginPage
            focus: true

            RowLayout {
                anchors.centerIn: parent
                spacing: 28

                ColumnLayout {
                    id: loginFormColumn
                    spacing: 18
                    implicitWidth: Math.min(460, root.width * 0.4)

                    Text {
                        text: "Rezka Native TV"
                        color: "white"
                        font.pixelSize: 42
                        font.bold: true
                        Layout.alignment: Qt.AlignHCenter
                    }

                    TextField {
                        id: email
                        placeholderText: "Email"
                        font.pixelSize: 24
                        Layout.fillWidth: true
                        focus: true
                        KeyNavigation.down: password
                        KeyNavigation.up: updateCheckLoginButton
                        Keys.priority: Keys.BeforeItem
                        Keys.onPressed: function (event) {
                            if (event.key === root.hkBack) {
                                event.accepted = true
                                root.tvLoginPageBack()
                            }
                        }
                        Keys.onDownPressed: function (event) {
                            password.forceActiveFocus()
                            event.accepted = true
                        }
                        Keys.onUpPressed: function (event) {
                            updateCheckLoginButton.forceActiveFocus()
                            event.accepted = true
                        }
                        Keys.onRightPressed: function (event) {
                            password.forceActiveFocus()
                            event.accepted = true
                        }
                        Keys.onLeftPressed: function (event) {
                            loginButton.forceActiveFocus()
                            event.accepted = true
                        }
                        background: Rectangle {
                            radius: 8
                            color: "#202020"
                            border.width: email.activeFocus ? 3 : 1
                            border.color: email.activeFocus ? "#b7d7ff" : "#3c3c3c"
                        }
                    }

                    TextField {
                        id: password
                        placeholderText: "Password"
                        echoMode: TextInput.Password
                        font.pixelSize: 24
                        Layout.fillWidth: true
                        KeyNavigation.up: email
                        KeyNavigation.down: loginButton
                        Keys.priority: Keys.BeforeItem
                        Keys.onPressed: function (event) {
                            if (event.key === root.hkBack) {
                                event.accepted = true
                                root.tvLoginPageBack()
                            }
                        }
                        Keys.onDownPressed: function (event) {
                            loginButton.forceActiveFocus()
                            event.accepted = true
                        }
                        Keys.onUpPressed: function (event) {
                            email.forceActiveFocus()
                            event.accepted = true
                        }
                        Keys.onRightPressed: function (event) {
                            loginButton.forceActiveFocus()
                            event.accepted = true
                        }
                        Keys.onLeftPressed: function (event) {
                            email.forceActiveFocus()
                            event.accepted = true
                        }
                        background: Rectangle {
                            radius: 8
                            color: "#202020"
                            border.width: password.activeFocus ? 3 : 1
                            border.color: password.activeFocus ? "#b7d7ff" : "#3c3c3c"
                        }
                    }

                    TvButton {
                        id: loginButton
                        text: "Войти"
                        font.pixelSize: 24
                        Layout.fillWidth: true
                        KeyNavigation.up: password
                        KeyNavigation.down: updateCheckLoginButton
                        Keys.onUpPressed: function (event) {
                            password.forceActiveFocus()
                            event.accepted = true
                        }
                        Keys.onDownPressed: function (event) {
                            updateCheckLoginButton.forceActiveFocus()
                            event.accepted = true
                        }
                        Keys.onRightPressed: function (event) {
                            email.forceActiveFocus()
                            event.accepted = true
                        }
                        Keys.onLeftPressed: function (event) {
                            password.forceActiveFocus()
                            event.accepted = true
                        }

                        onClicked: {
                            errorText.text = ""
                            backend.login(email.text, password.text)
                        }
                    }

                    TvButton {
                        id: updateCheckLoginButton
                        text: "Проверить обновления"
                        font.pixelSize: 20
                        Layout.fillWidth: true
                        KeyNavigation.up: loginButton
                        KeyNavigation.down: email
                        Keys.onUpPressed: function (event) {
                            loginButton.forceActiveFocus()
                            event.accepted = true
                        }
                        Keys.onDownPressed: function (event) {
                            email.forceActiveFocus()
                            event.accepted = true
                        }
                        Keys.onRightPressed: function (event) {
                            email.forceActiveFocus()
                            event.accepted = true
                        }
                        Keys.onLeftPressed: function (event) {
                            password.forceActiveFocus()
                            event.accepted = true
                        }
                        onClicked: backend.checkForAppUpdate()
                    }

                    Text {
                        id: errorText
                        color: "#ff7777"
                        font.pixelSize: 18
                        Layout.fillWidth: true
                        wrapMode: Text.WordWrap
                    }

                    Text {
                        text: loadingMessage
                        color: "#bbbbbb"
                        font.pixelSize: 18
                        Layout.fillWidth: true
                        wrapMode: Text.WordWrap
                        visible: loadingMessage.length > 0
                    }
                }

                ColumnLayout {
                    spacing: 8
                    Layout.minimumWidth: 168
                    Layout.maximumWidth: 220
                    Layout.alignment: Qt.AlignTop
                    Layout.topMargin: 6

                    Image {
                        width: 160
                        height: 160
                        fillMode: Image.PreserveAspectFit
                        source: root.companionLoginQr
                        asynchronous: false
                        cache: false
                        Layout.alignment: Qt.AlignHCenter
                    }
                }
            }

            Keys.onPressed: function (event) {
                if (root.tvHotkeysWizardVisible && root.tvWizardApplyKey(event))
                    return
                var left = event.key === root.hkLeft || event.key === Qt.Key_Left
                var right = event.key === root.hkRight || event.key === Qt.Key_Right
                if ((left || right) && loginFormNavigateHorizontal(right)) {
                    event.accepted = true
                    return
                }
                if (event.key === root.hkBack)
                    backend.quit()
            }
        }

        Item {
            id: continuePage
            focus: true

            Keys.onPressed: function (event) {
                if (root.tvHotkeysWizardVisible && root.tvWizardApplyKey(event))
                    return
                var left = event.key === root.hkLeft || event.key === Qt.Key_Left
                var right = event.key === root.hkRight || event.key === Qt.Key_Right
                if (!left && !right)
                    return
                if (continueToolbarNavigateHorizontal(right)) {
                    event.accepted = true
                    return
                }
            }

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 40
                spacing: 24

                RowLayout {
                    Layout.fillWidth: true

                    Text {
                        text: listTitle
                        color: "white"
                        font.pixelSize: 36
                        font.bold: true
                        Layout.fillWidth: true
                    }

                    TvButton {
                        id: continueTabButton
                        text: "Досмотреть"
                        font.pixelSize: 20
                        onClicked: {
                            listTitle = "Последние просмотренные"
                            backend.loadContinue()
                            grid.forceActiveFocus()
                        }
                        KeyNavigation.right: searchField
                        KeyNavigation.down: grid
                    }

                    TextField {
                        id: searchField
                        Layout.preferredWidth: Math.min(260, Math.max(180, continuePage.width * 0.22))
                        placeholderText: "Поиск"
                        font.pixelSize: 18
                        Keys.priority: Keys.BeforeItem
                        Keys.onPressed: function (event) {
                            if (event.key === root.hkBack) {
                                event.accepted = true
                                root.tvContinueToolbarBackFromSearch()
                            }
                        }
                        background: Rectangle {
                            radius: 8
                            color: "#202020"
                            border.width: searchField.activeFocus ? 3 : 1
                            border.color: searchField.activeFocus ? "#b7d7ff" : "#3c3c3c"
                        }
                        onAccepted: {
                            listTitle = "Поиск: " + text
                            backend.search(text)
                            grid.forceActiveFocus()
                        }
                        KeyNavigation.left: continueTabButton
                        KeyNavigation.right: searchButton
                        KeyNavigation.down: grid
                    }

                    Item {
                        Layout.preferredWidth: 52
                        Layout.preferredHeight: 52
                        Layout.maximumWidth: 52
                        Layout.maximumHeight: 52
                        Layout.alignment: Qt.AlignVCenter
                        Image {
                            anchors.fill: parent
                            fillMode: Image.PreserveAspectFit
                            source: root.companionSearchQr
                            asynchronous: false
                            cache: false
                        }
                    }

                    TvButton {
                        id: searchButton
                        text: "Найти"
                        font.pixelSize: 20
                        onClicked: {
                            listTitle = "Поиск: " + searchField.text
                            backend.search(searchField.text)
                            grid.forceActiveFocus()
                        }
                        KeyNavigation.left: searchField
                        KeyNavigation.right: updateCheckToolbarButton
                        KeyNavigation.down: grid
                    }

                    TvButton {
                        id: updateCheckToolbarButton
                        text: "Обновления"
                        font.pixelSize: 20
                        onClicked: backend.checkForAppUpdate()
                        KeyNavigation.left: searchButton
                        KeyNavigation.right: quitButton
                        KeyNavigation.down: grid
                    }

                    TvButton {
                        id: quitButton
                        text: "Выход"
                        font.pixelSize: 20
                        onClicked: backend.quit()
                        KeyNavigation.left: updateCheckToolbarButton
                        KeyNavigation.down: grid
                    }
                }

                ListView {
                    id: grid
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    focus: true
                    model: historyItems
                    clip: true
                    spacing: 10

                    delegate: Rectangle {
                        id: historyRow
                        width: ListView.view.width
                        height: 148
                        radius: 8
                        color: ListView.isCurrentItem && grid.activeFocus ? "#3d6fb6" : ListView.isCurrentItem ? "#2f4f78" : "#242424"
                        border.width: ListView.isCurrentItem ? 3 : 1
                        border.color: ListView.isCurrentItem && grid.activeFocus ? "#b7d7ff" : "#4a4a4a"
                        property int _clickStep: 0

                        RowLayout {
                            anchors.fill: parent
                            anchors.margins: 14
                            spacing: 16

                            Image {
                                source: modelData.image || ""
                                Layout.preferredWidth: 150
                                Layout.fillHeight: true
                                fillMode: Image.PreserveAspectCrop
                                clip: true
                            }

                            ColumnLayout {
                                Layout.fillWidth: true
                                Layout.fillHeight: true
                                spacing: 8

                                Text {
                                    text: modelData.title || "Без названия"
                                    color: "white"
                                    font.pixelSize: 24
                                    font.bold: true
                                    wrapMode: Text.WordWrap
                                    maximumLineCount: 2
                                    elide: Text.ElideRight
                                    Layout.fillWidth: true
                                }

                                Text {
                                    text: modelData.info || modelData.year || ""
                                    color: "#d6d6d6"
                                    font.pixelSize: 18
                                    wrapMode: Text.WordWrap
                                    maximumLineCount: 2
                                    elide: Text.ElideRight
                                    Layout.fillWidth: true
                                }

                                Text {
                                    text: modelData.date || ""
                                    color: "#aaaaaa"
                                    font.pixelSize: 16
                                    maximumLineCount: 1
                                    elide: Text.ElideRight
                                    Layout.fillWidth: true
                                }

                                Text {
                                    text: itemHasContinue(modelData) ? resumeText(modelData) : ""
                                    color: "#8ec7ff"
                                    font.pixelSize: 16
                                    maximumLineCount: 1
                                    elide: Text.ElideRight
                                    Layout.fillWidth: true
                                    visible: itemHasContinue(modelData)
                                }
                            }
                        }

                        MouseArea {
                            anchors.fill: parent
                            onClicked: {
                                grid.currentIndex = index
                                grid.forceActiveFocus()
                                if (historyRow._clickStep === 0) {
                                    historyRow._clickStep = 1
                                    rowClickTimer.restart()
                                } else {
                                    rowClickTimer.stop()
                                    historyRow._clickStep = 0
                                    openListItem(modelData)
                                }
                            }
                        }

                        Timer {
                            id: rowClickTimer
                            interval: 380
                            repeat: false
                            onTriggered: historyRow._clickStep = 0
                        }
                    }

                    Keys.onPressed: function (event) {
                        if (root.tvHotkeysWizardVisible && root.tvWizardApplyKey(event))
                            return
                        if (event.key === root.hkBack) {
                            if (!loggedIn) {
                                stack.currentIndex = 0
                                email.forceActiveFocus()
                            } else {
                                event.accepted = true
                                continueTabButton.forceActiveFocus()
                            }
                            return
                        }
                        if (root.isTvActivateButton(event)) {
                            if (currentIndex >= 0 && historyItems[currentIndex]) {
                                openListItem(historyItems[currentIndex])
                                event.accepted = true
                            }
                            return
                        }
                        if (event.key === root.hkUp || event.key === Qt.Key_Up) {
                            if (currentIndex <= 0) {
                                continueTabButton.forceActiveFocus()
                                event.accepted = true
                            } else {
                                grid.currentIndex = grid.currentIndex - 1
                                event.accepted = true
                            }
                            return
                        }
                        if (event.key === root.hkDown || event.key === Qt.Key_Down) {
                            if (currentIndex < grid.count - 1) {
                                grid.currentIndex = grid.currentIndex + 1
                                event.accepted = true
                            }
                            return
                        }
                    }
                }

                Text {
                    text: loadingMessage
                    color: "#bbbbbb"
                    font.pixelSize: 18
                    Layout.fillWidth: true
                    visible: loadingMessage.length > 0
                }
            }
        }

        Item {
            id: detailsPage
            focus: true

            RowLayout {
                anchors.fill: parent
                anchors.margins: 36
                spacing: 28

                Rectangle {
                    Layout.preferredWidth: Math.min(320, Math.max(220, detailsPage.width * 0.28))
                    Layout.fillHeight: true
                    radius: 22
                    color: "#1d1d1d"

                    ColumnLayout {
                        anchors.fill: parent
                        anchors.margins: 18
                        spacing: 16

                        Image {
                            source: selectedMovie.thumbnailHQ || selectedMovie.thumbnail || ""
                            Layout.fillWidth: true
                            Layout.preferredHeight: 450
                            fillMode: Image.PreserveAspectFit
                        }

                        Text {
                            text: ratingText()
                            color: "#ffd37a"
                            font.pixelSize: 20
                            wrapMode: Text.WordWrap
                            Layout.fillWidth: true
                        }

                        Text {
                            text: selectedMovie.category || ""
                            color: "#bbbbbb"
                            font.pixelSize: 16
                            wrapMode: Text.WordWrap
                            Layout.fillWidth: true
                        }
                    }
                }

                ColumnLayout {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    spacing: 16

                    RowLayout {
                        Layout.fillWidth: true

                        Text {
                            text: selectedMovie.name || "Без названия"
                            color: "white"
                            font.pixelSize: 38
                            font.bold: true
                            wrapMode: Text.WordWrap
                            Layout.fillWidth: true
                        }

                        TvButton {
                            id: detailsBackButton
                            text: "Назад"
                            font.pixelSize: 20
                            onClicked: {
                                stack.currentIndex = 1
                                grid.forceActiveFocus()
                            }
                            KeyNavigation.down: continueWatchButton.visible ? continueWatchButton : watchButton
                        }
                    }

                    Text {
                        text: selectedMovie.description || ""
                        color: "#dddddd"
                        font.pixelSize: 18
                        lineHeight: 1.15
                        wrapMode: Text.WordWrap
                        maximumLineCount: 5
                        elide: Text.ElideRight
                        Layout.fillWidth: true
                    }

                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 12

                        TvButton {
                            id: continueWatchButton
                            text: resumeText(selectedListItem)
                            font.pixelSize: 22
                            Layout.fillWidth: true
                            visible: itemHasContinue(selectedListItem)
                            enabled: loadingMessage !== "Получаем видеопоток..."
                            onClicked: continueWatch()

                            KeyNavigation.up: detailsBackButton
                            KeyNavigation.down: watchButton
                            KeyNavigation.left: continueWatchButton
                            KeyNavigation.right: continueWatchButton
                        }

                        TvButton {
                            id: watchButton
                            text: "Смотреть"
                            font.pixelSize: 22
                            Layout.fillWidth: true
                            enabled: loadingMessage !== "Получаем видеопоток..."
                            onClicked: startWatchSelectionFlow()

                            KeyNavigation.up: continueWatchButton.visible ? continueWatchButton : detailsBackButton
                            KeyNavigation.down: detailsBackButton
                            KeyNavigation.left: watchButton
                            KeyNavigation.right: watchButton
                        }
                    }

                    Text {
                        text: itemHasContinue(selectedListItem) ? resumeText(selectedListItem) : ""
                        color: "#8ec7ff"
                        font.pixelSize: 18
                        Layout.fillWidth: true
                        visible: itemHasContinue(selectedListItem)
                    }

                    Text {
                        text: {
                            const ext = selectedMovie.externalRatings || ({})
                            let parts = []
                            if (ext.kinopoisk)
                                parts.push("Кинопоиск: " + ext.kinopoisk)
                            if (ext.imdb)
                                parts.push("IMDb: " + ext.imdb)
                            return parts.length > 0 ? parts.join("   |   ") : ""
                        }
                        color: "#8e8e8e"
                        font.pixelSize: 17
                        Layout.fillWidth: true
                        wrapMode: Text.WordWrap
                        visible: text.length > 0
                    }

                    Text {
                        text: selectedMovie.director ? ("Режиссёр: " + selectedMovie.director) : ""
                        color: "#cfcfcf"
                        font.pixelSize: 17
                        Layout.fillWidth: true
                        wrapMode: Text.WordWrap
                        visible: text.length > 0
                    }

                    Text {
                        text: selectedMovie.actors ? ("Актёры: " + selectedMovie.actors) : ""
                        color: "#cfcfcf"
                        font.pixelSize: 17
                        Layout.fillWidth: true
                        wrapMode: Text.WordWrap
                        maximumLineCount: 2
                        elide: Text.ElideRight
                        visible: text.length > 0
                    }

                    Text {
                        id: detailsErrorText
                        color: "#ff7777"
                        font.pixelSize: 17
                        wrapMode: Text.WordWrap
                        Layout.fillWidth: true
                    }

                    Text {
                        text: loadingMessage
                        color: "#bbbbbb"
                        font.pixelSize: 17
                        wrapMode: Text.WordWrap
                        Layout.fillWidth: true
                        visible: loadingMessage.length > 0
                    }

                    Item {
                        Layout.fillHeight: true
                        visible: !!selectedMovie.isSeries
                    }
                }
            }

            Rectangle {
                anchors.fill: parent
                color: "#99000000"
                visible: streamLoading && stack.currentIndex === 2
                z: 10

                Column {
                    anchors.centerIn: parent
                    spacing: 18

                    BusyIndicator {
                        running: parent.parent.visible
                        width: 72
                        height: 72
                        anchors.horizontalCenter: parent.horizontalCenter
                    }

                    Text {
                        text: "Получаем видеопоток..."
                        color: "white"
                        font.pixelSize: 24
                        font.bold: true
                    }
                }
            }

            Keys.onPressed: function (event) {
                if (root.tvHotkeysWizardVisible && root.tvWizardApplyKey(event))
                    return
                if (stack.currentIndex === 2 && !translatorModal.visible && !qualityModal.visible && !seasonEpisodeModal.visible) {
                    var k = event.key
                    var onBack = detailsBackButton.activeFocus
                    var onCont = continueWatchButton.visible && continueWatchButton.activeFocus
                    var onWatch = watchButton.activeFocus
                    var onBtn = onBack || onCont || onWatch
                    if (!onBtn && (k === root.hkUp || k === root.hkDown || k === root.hkLeft || k === root.hkRight)) {
                        watchButton.forceActiveFocus()
                        event.accepted = true
                        return
                    }
                    if (k === root.hkDown) {
                        if (onBack) {
                            if (continueWatchButton.visible)
                                continueWatchButton.forceActiveFocus()
                            else
                                watchButton.forceActiveFocus()
                            event.accepted = true
                            return
                        }
                        if (onCont) {
                            watchButton.forceActiveFocus()
                            event.accepted = true
                            return
                        }
                        if (onWatch) {
                            detailsBackButton.forceActiveFocus()
                            event.accepted = true
                            return
                        }
                    }
                    if (k === root.hkUp) {
                        if (onWatch) {
                            if (continueWatchButton.visible)
                                continueWatchButton.forceActiveFocus()
                            else
                                detailsBackButton.forceActiveFocus()
                            event.accepted = true
                            return
                        }
                        if (onCont) {
                            detailsBackButton.forceActiveFocus()
                            event.accepted = true
                            return
                        }
                        if (onBack) {
                            event.accepted = true
                            return
                        }
                    }
                    if (k === root.hkLeft || k === root.hkRight) {
                        if (onWatch && continueWatchButton.visible) {
                            continueWatchButton.forceActiveFocus()
                            event.accepted = true
                            return
                        }
                        if (onCont) {
                            watchButton.forceActiveFocus()
                            event.accepted = true
                            return
                        }
                    }
                }
                if (event.key !== root.hkBack)
                    return
                event.accepted = true
                stack.currentIndex = 1
                grid.forceActiveFocus()
            }

            Popup {
                id: translatorModal
                anchors.centerIn: parent
                width: Math.min(780, parent.width - 80)
                height: Math.min(560, parent.height - 80)
                modal: true
                focus: true
                closePolicy: Popup.CloseOnEscape
                background: Rectangle {
                    color: "#f0151515"
                    radius: 12
                    border.width: 2
                    border.color: "#6fa8df"
                }
                onOpened: {
                    translatorList.currentIndex = selectedTranslatorIndex
                    translatorList.forceActiveFocus()
                }

                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: 16
                    spacing: 12
                    Text {
                        text: "Выберите озвучку"
                        color: "white"
                        font.pixelSize: 30
                        font.bold: true
                    }
                    ListView {
                        id: translatorList
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        model: translatorsModel()
                        clip: true
                        spacing: 8
                        delegate: TvButton {
                            tvPassNavigationKeys: true
                            width: ListView.view.width
                            text: modelData.translator_name || ("Озвучка " + (index + 1))
                            checkable: true
                            checked: index === translatorList.currentIndex
                            onClicked: {
                                setTranslatorIndex(index, false)
                                translatorModal.close()
                                if (watchSetupFlow) {
                                    qualityModal.open()
                                    qualityList.forceActiveFocus()
                                } else {
                                    watchButton.forceActiveFocus()
                                }
                            }
                        }
                        Keys.onPressed: function (event) {
                            if (root.tvHotkeysWizardVisible && root.tvWizardApplyKey(event))
                                return
                            if (event.key === root.hkDown || event.key === Qt.Key_Down) {
                                if (currentIndex < count - 1) {
                                    currentIndex = currentIndex + 1
                                }
                                event.accepted = true
                                return
                            }
                            if (event.key === root.hkUp || event.key === Qt.Key_Up) {
                                if (currentIndex > 0) {
                                    currentIndex = currentIndex - 1
                                }
                                event.accepted = true
                                return
                            }
                            if (root.isTvActivateButton(event)) {
                                if (currentIndex >= 0) {
                                    setTranslatorIndex(currentIndex, false)
                                    translatorModal.close()
                                    if (watchSetupFlow) {
                                        qualityModal.open()
                                        qualityList.forceActiveFocus()
                                    } else {
                                        watchButton.forceActiveFocus()
                                    }
                                }
                                event.accepted = true
                                return
                            }
                            if (event.key !== root.hkBack)
                                return
                            translatorModal.close()
                            watchSetupFlow = false
                            watchButton.forceActiveFocus()
                            event.accepted = true
                        }
                    }
                }
            }

            Popup {
                id: qualityModal
                anchors.centerIn: parent
                width: Math.min(560, parent.width - 80)
                height: Math.min(520, parent.height - 80)
                modal: true
                focus: true
                closePolicy: Popup.CloseOnEscape
                background: Rectangle {
                    color: "#f0151515"
                    radius: 12
                    border.width: 2
                    border.color: "#6fa8df"
                }
                onOpened: {
                    qualityList.currentIndex = Math.max(0, qualityOptions.indexOf(selectedQuality))
                    qualityList.forceActiveFocus()
                }

                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: 16
                    spacing: 12
                    Text {
                        text: "Выберите качество"
                        color: "white"
                        font.pixelSize: 30
                        font.bold: true
                    }
                    ListView {
                        id: qualityList
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        model: qualityOptions
                        clip: true
                        spacing: 8
                        delegate: TvButton {
                            tvPassNavigationKeys: true
                            width: ListView.view.width
                            text: modelData
                            checkable: true
                            checked: index === qualityList.currentIndex
                            onClicked: {
                                selectedQuality = modelData
                                qualityModal.close()
                                if (watchSetupFlow) {
                                    watchSetupFlow = false
                                    startWatchAt(0)
                                } else {
                                    watchButton.forceActiveFocus()
                                }
                            }
                        }
                        Keys.onPressed: function (event) {
                            if (root.tvHotkeysWizardVisible && root.tvWizardApplyKey(event))
                                return
                            if (event.key === root.hkDown || event.key === Qt.Key_Down) {
                                if (currentIndex < count - 1) {
                                    currentIndex = currentIndex + 1
                                }
                                event.accepted = true
                                return
                            }
                            if (event.key === root.hkUp || event.key === Qt.Key_Up) {
                                if (currentIndex > 0) {
                                    currentIndex = currentIndex - 1
                                }
                                event.accepted = true
                                return
                            }
                            if (root.isTvActivateButton(event)) {
                                if (currentIndex >= 0) {
                                    selectedQuality = qualityOptions[currentIndex]
                                    qualityModal.close()
                                    if (watchSetupFlow) {
                                        watchSetupFlow = false
                                        startWatchAt(0)
                                    } else {
                                        watchButton.forceActiveFocus()
                                    }
                                }
                                event.accepted = true
                                return
                            }
                            if (event.key !== root.hkBack)
                                return
                            qualityModal.close()
                            watchSetupFlow = false
                            watchButton.forceActiveFocus()
                            event.accepted = true
                        }
                    }
                }
            }

            Popup {
                id: seasonEpisodeModal
                anchors.centerIn: parent
                width: Math.min(980, parent.width - 80)
                height: Math.min(620, parent.height - 80)
                modal: true
                focus: true
                closePolicy: Popup.CloseOnEscape
                background: Rectangle {
                    color: "#f0151515"
                    radius: 12
                    border.width: 2
                    border.color: "#6fa8df"
                }
                onOpened: {
                    modalSeasonIndex = selectedSeasonIndex
                    modalEpisodeIndex = selectedEpisodeIndex
                    modalSeasonsList.currentIndex = modalSeasonIndex
                    modalEpisodesList.currentIndex = modalEpisodeIndex
                    modalSeasonsList.forceActiveFocus()
                }

                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: 16
                    spacing: 12
                    Text {
                        text: "Выберите сезон и серию"
                        color: "white"
                        font.pixelSize: 30
                        font.bold: true
                    }
                    RowLayout {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        spacing: 14
                        ListView {
                            id: modalSeasonsList
                            Layout.fillHeight: true
                            Layout.preferredWidth: 280
                            model: seasonsModel()
                            clip: true
                            spacing: 8
                            delegate: TvButton {
                                tvPassNavigationKeys: true
                                width: ListView.view.width
                                text: modelData.season_text || ("Сезон " + modelData.season)
                                checkable: true
                                checked: index === modalSeasonIndex
                                onClicked: {
                                    modalSeasonIndex = index
                                    modalEpisodeIndex = 0
                                    modalEpisodesList.currentIndex = 0
                                    modalEpisodesList.forceActiveFocus()
                                }
                            }
                            Keys.onPressed: function (event) {
                                if (root.tvHotkeysWizardVisible && root.tvWizardApplyKey(event))
                                    return
                                if (event.key === root.hkDown || event.key === Qt.Key_Down) {
                                    if (currentIndex < count - 1) {
                                        currentIndex = currentIndex + 1
                                        modalSeasonIndex = currentIndex
                                        modalEpisodeIndex = 0
                                        modalEpisodesList.currentIndex = 0
                                    }
                                    event.accepted = true
                                    return
                                }
                                if (event.key === root.hkUp || event.key === Qt.Key_Up) {
                                    if (currentIndex > 0) {
                                        currentIndex = currentIndex - 1
                                        modalSeasonIndex = currentIndex
                                        modalEpisodeIndex = 0
                                        modalEpisodesList.currentIndex = 0
                                    }
                                    event.accepted = true
                                    return
                                }
                                if (event.key === root.hkRight || event.key === Qt.Key_Right) {
                                    modalEpisodesList.forceActiveFocus()
                                    event.accepted = true
                                    return
                                }
                                if (root.isTvActivateButton(event)) {
                                    if (currentIndex >= 0) {
                                        modalSeasonIndex = currentIndex
                                        modalEpisodeIndex = 0
                                        modalEpisodesList.currentIndex = 0
                                        modalEpisodesList.forceActiveFocus()
                                    }
                                    event.accepted = true
                                    return
                                }
                                if (event.key !== root.hkBack)
                                    return
                                seasonEpisodeModal.close()
                                watchSetupFlow = false
                                watchButton.forceActiveFocus()
                                event.accepted = true
                            }
                        }
                        ListView {
                            id: modalEpisodesList
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            model: {
                                const seasons = seasonsModel()
                                const season = seasons[modalSeasonIndex]
                                return season && season.episodes ? season.episodes : []
                            }
                            clip: true
                            spacing: 8
                            delegate: TvButton {
                                tvPassNavigationKeys: true
                                width: ListView.view.width
                                text: modelData.episode_text || ("Серия " + modelData.episode)
                                checkable: true
                                checked: index === modalEpisodeIndex
                                onClicked: {
                                    modalEpisodeIndex = index
                                    setSeasonIndex(modalSeasonIndex)
                                    setEpisodeIndex(modalEpisodeIndex)
                                    seasonEpisodeModal.close()
                                    translatorModal.open()
                                    translatorList.forceActiveFocus()
                                }
                            }
                            Keys.onPressed: function (event) {
                                if (root.tvHotkeysWizardVisible && root.tvWizardApplyKey(event))
                                    return
                                if (event.key === root.hkDown || event.key === Qt.Key_Down) {
                                    if (currentIndex < count - 1) {
                                        currentIndex = currentIndex + 1
                                        modalEpisodeIndex = currentIndex
                                    }
                                    event.accepted = true
                                    return
                                }
                                if (event.key === root.hkUp || event.key === Qt.Key_Up) {
                                    if (currentIndex > 0) {
                                        currentIndex = currentIndex - 1
                                        modalEpisodeIndex = currentIndex
                                    }
                                    event.accepted = true
                                    return
                                }
                                if (event.key === root.hkLeft || event.key === Qt.Key_Left) {
                                    modalSeasonsList.forceActiveFocus()
                                    event.accepted = true
                                    return
                                }
                                if (root.isTvActivateButton(event)) {
                                    if (currentIndex >= 0) {
                                        modalEpisodeIndex = currentIndex
                                        setSeasonIndex(modalSeasonIndex)
                                        setEpisodeIndex(modalEpisodeIndex)
                                        seasonEpisodeModal.close()
                                        translatorModal.open()
                                        translatorList.forceActiveFocus()
                                    }
                                    event.accepted = true
                                    return
                                }
                                if (event.key !== root.hkBack)
                                    return
                                seasonEpisodeModal.close()
                                watchSetupFlow = false
                                watchButton.forceActiveFocus()
                                event.accepted = true
                            }
                        }
                        TvButton {
                            text: "Отмена"
                            Layout.alignment: Qt.AlignRight
                            onClicked: {
                                seasonEpisodeModal.close()
                                watchSetupFlow = false
                                watchButton.forceActiveFocus()
                            }
                        }
                    }
                }
            }
        }

        Item {
            id: playerPage
            focus: true

            Rectangle {
                anchors.fill: parent
                color: "black"

                VideoOutput {
                    id: videoOutput
                    anchors.fill: parent
                    fillMode: VideoOutput.PreserveAspectFit
                }

                // Клик по видео: для пультов в режиме «мышь» (ЛКМ), когда панель скрыта — пауза/воспроизведение как пробел.
                MouseArea {
                    anchors.fill: parent
                    z: 1
                    hoverEnabled: true
                    acceptedButtons: Qt.LeftButton
                    cursorShape: Qt.BlankCursor
                    onPositionChanged: showPlayerControls()
                    onClicked: function (mouse) {
                        if (stack.currentIndex !== 3)
                            return
                        if (mouse.button === Qt.LeftButton) {
                            if (playerControlsVisible)
                                showPlayerControls()
                            else
                                playerPage.togglePlayPauseFromRemote()
                        }
                    }
                }

                Rectangle {
                    z: 2
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    height: playerTopInfoCol.implicitHeight + 20
                    visible: playerControlsVisible && stack.currentIndex === 3
                    color: "#b3000000"
                    Column {
                        id: playerTopInfoCol
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.top: parent.top
                        anchors.margins: 14
                        spacing: 6

                        Text {
                            text: selectedMovie.name || currentStream.name || ""
                            color: "white"
                            font.pixelSize: 22
                            font.bold: true
                            width: parent.width
                            wrapMode: Text.WordWrap
                            maximumLineCount: 2
                            elide: Text.ElideRight
                        }

                        Text {
                            text: playerTopEpisodeLine()
                            color: "#c8dcff"
                            font.pixelSize: 17
                            width: parent.width
                            visible: text.length > 0
                            wrapMode: Text.WordWrap
                            elide: Text.ElideRight
                        }
                    }
                }

                MediaPlayer {
                    id: mediaPlayer
                    objectName: "mediaPlayer"
                    videoOutput: videoOutput
                    audioOutput: AudioOutput {
                        id: playerStreamAudio
                    }
                    Component.onCompleted: backend.configureMediaPlayer(mediaPlayer)

                    onMediaStatusChanged: {
                        if (mediaStatus === MediaPlayer.InvalidMedia)
                            qualitySwitchInFlight = false
                        if (qualitySwitchInFlight && (mediaStatus === MediaPlayer.BufferedMedia || mediaStatus === MediaPlayer.LoadedMedia)) {
                            if (pendingSeekPosition > 0)
                                mediaPlayer.setPosition(pendingSeekPosition)
                            if (qualitySwitchResumePlay)
                                mediaPlayer.play()
                            else
                                mediaPlayer.pause()
                            qualitySwitchInFlight = false
                        } else if (pendingSeekPosition > 0 && (mediaStatus === MediaPlayer.BufferedMedia || mediaStatus === MediaPlayer.LoadedMedia)) {
                            mediaPlayer.setPosition(pendingSeekPosition)
                        }
                        if (mediaStatus === MediaPlayer.EndOfMedia) {
                            backend.saveWatchProgress(mediaPlayer.duration, mediaPlayer.duration, lastProgressPosition)
                            if (canGoNextEpisode())
                                playNextEpisode()
                            else
                                playerControlsVisible = true
                        }
                    }

                    onPlaybackStateChanged: {
                        if (playbackState === MediaPlayer.PlayingState)
                            controlsHideTimer.restart()
                        else
                            playerControlsVisible = true
                    }

                }

                Timer {
                    id: controlsHideTimer
                    interval: 5000
                    repeat: false
                    onTriggered: {
                        if (stack.currentIndex === 3 && mediaPlayer.playbackState === MediaPlayer.PlayingState && !playerSubtitleModal.visible && !playerQualityModal.visible) {
                            playerControlsVisible = false
                            playerPage.forceActiveFocus()
                        }
                    }
                }

                Timer {
                    interval: 250
                    repeat: true
                    running: stack.currentIndex === 3 && subtitleCues.length > 0
                    onTriggered: updateSubtitleText()
                }

                Timer {
                    interval: 15000
                    repeat: true
                    running: stack.currentIndex === 3 && mediaPlayer.source !== ""
                    onTriggered: {
                        backend.saveWatchProgress(mediaPlayer.position, mediaPlayer.duration, lastProgressPosition)
                        lastProgressPosition = mediaPlayer.position
                    }
                }

                Timer {
                    interval: 250
                    repeat: true
                    running: stack.currentIndex === 3 && pendingSeekPosition > 0 && pendingSeekAttempts < 80
                    onTriggered: {
                        pendingSeekAttempts++
                        if (mediaPlayer.duration > 0) {
                            if (mediaPlayer.duration < pendingSeekPosition)
                                pendingSeekPosition = Math.max(0, mediaPlayer.duration - 1500)
                        }
                        if (mediaPlayer.duration > 0 && mediaPlayer.duration < pendingSeekPosition)
                            return
                        // Пока длительность неизвестна, подождать пару тиков, затем пробовать seek.
                        if (mediaPlayer.duration <= 0 && pendingSeekAttempts < 3)
                            return

                        mediaPlayer.setPosition(pendingSeekPosition)
                        if (Math.abs(mediaPlayer.position - pendingSeekPosition) < 2500)
                            pendingSeekPosition = 0
                        else if (pendingSeekAttempts >= 80)
                            pendingSeekPosition = 0
                    }
                }

                Text {
                    z: 4
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    anchors.bottomMargin: (playerControls.visible ? playerControls.height : 0) + subtitleSafeBottomGap
                    anchors.leftMargin: 72
                    anchors.rightMargin: 72
                    text: activeSubtitleText
                    color: "#c9c9c9"
                    font.pixelSize: subtitleFontSize
                    font.bold: true
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.WordWrap
                    style: Text.Outline
                    styleColor: "#202020"
                    visible: activeSubtitleText.length > 0
                }

                Rectangle {
                    z: 3
                    anchors.centerIn: parent
                    width: 360
                    height: 140
                    radius: 8
                    color: "#cc000000"
                    visible: bufferingVisible

                    Column {
                        anchors.centerIn: parent
                        spacing: 14

                        BusyIndicator {
                            running: parent.parent.visible
                            width: 54
                            height: 54
                            anchors.horizontalCenter: parent.horizontalCenter
                        }

                        Text {
                            text: streamLoading ? "Получаем видеопоток..." : "Буферизация..."
                            color: "white"
                            font.pixelSize: 22
                            font.bold: true
                            anchors.horizontalCenter: parent.horizontalCenter
                        }
                    }
                }

                FocusScope {
                    id: playerControls
                    z: 5
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    height: 168
                    visible: playerControlsVisible || mediaPlayer.playbackState !== MediaPlayer.PlayingState || streamLoading

                    Rectangle {
                        anchors.fill: parent
                        color: "#aa000000"

                        ColumnLayout {
                        anchors.fill: parent
                        anchors.margins: 18
                        spacing: 12

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 14

                            Text {
                                text: formatTime(mediaPlayer.position) + " / " + (mediaPlayer.duration > 0 ? formatTime(mediaPlayer.duration) : "--:--")
                                color: "#dddddd"
                                font.pixelSize: 18
                            }

                            Text {
                                text: mediaPlayer.duration > 0 ? "осталось " + formatTime(mediaPlayer.duration - mediaPlayer.position) : ""
                                color: "#bbbbbb"
                                font.pixelSize: 18
                                Layout.fillWidth: true
                                horizontalAlignment: Text.AlignRight
                            }
                        }

                        Rectangle {
                            Layout.fillWidth: true
                            Layout.preferredHeight: 10
                            radius: 5
                            color: "#444444"

                            Rectangle {
                                anchors.left: parent.left
                                anchors.top: parent.top
                                anchors.bottom: parent.bottom
                                width: parent.width * progressRatio()
                                radius: 5
                                color: "#75b7ff"
                            }
                        }

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 14

                            Rectangle {
                                Layout.preferredHeight: 56
                                implicitWidth: playbackRow.implicitWidth + 12
                                implicitHeight: playbackRow.implicitHeight + 12
                                color: "#332a2a2a"
                                radius: 10
                                border.width: 1
                                border.color: "#4a4a4a"
                                RowLayout {
                                    id: playbackRow
                                    anchors.centerIn: parent
                                    spacing: 6

                                    TvButton {
                                        id: playButton
                                        text: mediaPlayer.playbackState === MediaPlayer.PlayingState ? "||" : ">"
                                        font.pixelSize: 20
                                        font.family: "monospace"
                                        Layout.preferredWidth: 64
                                        onActiveFocusChanged: if (activeFocus)
                                            showPlayerControls()
                                        onClicked: {
                                            if (mediaPlayer.playbackState === MediaPlayer.PlayingState)
                                                mediaPlayer.pause()
                                            else
                                                mediaPlayer.play()
                                            showPlayerControls()
                                        }
                                        KeyNavigation.left: subtitleBiggerButton
                                        KeyNavigation.right: previousEpisodeButton.visible ? previousEpisodeButton : playerQualityButton
                                    }

                                    TvButton {
                                        id: previousEpisodeButton
                                        text: "<<"
                                        font.pixelSize: 20
                                        font.family: "monospace"
                                        Layout.preferredWidth: 64
                                        visible: !!selectedMovie.isSeries
                                        enabled: canGoPreviousEpisode()
                                        onActiveFocusChanged: if (activeFocus)
                                            showPlayerControls()
                                        onClicked: playPreviousEpisode()
                                        KeyNavigation.left: playButton
                                        KeyNavigation.right: nextEpisodeButton.visible ? nextEpisodeButton : playerQualityButton
                                    }

                                    TvButton {
                                        id: nextEpisodeButton
                                        text: ">>"
                                        font.pixelSize: 20
                                        font.family: "monospace"
                                        Layout.preferredWidth: 64
                                        visible: !!selectedMovie.isSeries
                                        enabled: canGoNextEpisode()
                                        onActiveFocusChanged: if (activeFocus)
                                            showPlayerControls()
                                        onClicked: playNextEpisode()
                                        KeyNavigation.left: previousEpisodeButton.visible ? previousEpisodeButton : playButton
                                        KeyNavigation.right: playerQualityButton
                                    }
                                }
                            }

                            Item {
                                Layout.fillWidth: true
                                Layout.preferredHeight: 56

                                Rectangle {
                                    anchors.right: parent.right
                                    anchors.verticalCenter: parent.verticalCenter
                                    implicitWidth: streamOptsRow.implicitWidth + 12
                                    implicitHeight: streamOptsRow.implicitHeight + 12
                                    color: "#332a2a2a"
                                    radius: 8
                                    border.width: 1
                                    border.color: "#383838"
                                    RowLayout {
                                        id: streamOptsRow
                                        anchors.centerIn: parent
                                        spacing: 6

                                        TvButton {
                                            id: playerQualityButton
                                            text: selectedQuality
                                            font.pixelSize: 20
                                            Layout.minimumWidth: 72
                                            Layout.maximumWidth: 200
                                            onActiveFocusChanged: if (activeFocus)
                                                showPlayerControls()
                                            onClicked: {
                                                playerQualityModal.open()
                                                playerQualityList.currentIndex = Math.max(0, (currentStream.availableQualities || []).indexOf(selectedQuality))
                                                playerQualityList.forceActiveFocus()
                                            }
                                            KeyNavigation.left: nextEpisodeButton.visible ? nextEpisodeButton : (previousEpisodeButton.visible ? previousEpisodeButton : playButton)
                                            KeyNavigation.right: subtitleSelectButton
                                        }

                                        TvButton {
                                            id: subtitleSelectButton
                                            text: selectedSubtitleTitle()
                                            font.pixelSize: 20
                                            Layout.minimumWidth: 72
                                            Layout.maximumWidth: 260
                                            onActiveFocusChanged: if (activeFocus)
                                                showPlayerControls()
                                            onClicked: {
                                                playerSubtitleModal.open()
                                                playerSubtitleList.currentIndex = selectedSubtitleIndex
                                                playerSubtitleList.forceActiveFocus()
                                            }
                                            KeyNavigation.left: playerQualityButton
                                            KeyNavigation.right: subtitleSmallerButton
                                        }
                                    }
                                }
                            }

                            Rectangle {
                                Layout.preferredHeight: 56
                                implicitWidth: subSizeRow.implicitWidth + 12
                                implicitHeight: subSizeRow.implicitHeight + 12
                                color: "#332a2a2a"
                                radius: 10
                                border.width: 1
                                border.color: "#4a4a4a"
                                RowLayout {
                                    id: subSizeRow
                                    anchors.centerIn: parent
                                    spacing: 6

                                    TvButton {
                                        id: subtitleSmallerButton
                                        text: "A-"
                                        font.pixelSize: 17
                                        Layout.preferredWidth: 52
                                        onActiveFocusChanged: if (activeFocus)
                                            showPlayerControls()
                                        onClicked: {
                                            subtitleFontSize = Math.max(18, subtitleFontSize - 2)
                                            showPlayerControls()
                                        }
                                        KeyNavigation.left: subtitleSelectButton
                                        KeyNavigation.right: subtitleBiggerButton
                                    }

                                    TvButton {
                                        id: subtitleBiggerButton
                                        text: "A+"
                                        font.pixelSize: 17
                                        Layout.preferredWidth: 52
                                        onActiveFocusChanged: if (activeFocus)
                                            showPlayerControls()
                                        onClicked: {
                                            subtitleFontSize = Math.min(52, subtitleFontSize + 2)
                                            showPlayerControls()
                                        }
                                        KeyNavigation.left: subtitleSmallerButton
                                        KeyNavigation.right: playButton
                                    }
                                }
                            }
                        }
                    }
                    }
                }

                Popup {
                    z: 6
                    id: playerQualityModal
                    anchors.centerIn: parent
                    width: Math.min(640, parent.width - 80)
                    height: Math.min(560, parent.height - 80)
                    modal: true
                    focus: true
                    closePolicy: Popup.CloseOnEscape
                    background: Rectangle {
                        color: "#f0151515"
                        radius: 12
                        border.width: 2
                        border.color: "#6fa8df"
                    }
                    onOpened: {
                        playerQualityList.currentIndex = Math.max(0, (currentStream.availableQualities || []).indexOf(selectedQuality))
                        playerQualityList.forceActiveFocus()
                    }

                    ColumnLayout {
                        anchors.fill: parent
                        anchors.margins: 16
                        spacing: 12
                        Text {
                            text: "Выберите качество"
                            color: "white"
                            font.pixelSize: 30
                            font.bold: true
                        }
                        ListView {
                            id: playerQualityList
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            model: currentStream.availableQualities || []
                            clip: true
                            spacing: 8
                            delegate: TvButton {
                                tvPassNavigationKeys: true
                                width: ListView.view.width
                                text: modelData
                                checkable: true
                                checked: index === playerQualityList.currentIndex
                                onClicked: {
                                    switchStreamQuality(modelData)
                                    playerQualityModal.close()
                                    playerQualityButton.forceActiveFocus()
                                }
                            }
                            Keys.onPressed: function (event) {
                                if (root.tvHotkeysWizardVisible && root.tvWizardApplyKey(event))
                                    return
                                if (event.key === root.hkDown || event.key === Qt.Key_Down) {
                                    if (currentIndex < count - 1) {
                                        currentIndex = currentIndex + 1
                                    }
                                    event.accepted = true
                                    return
                                }
                                if (event.key === root.hkUp || event.key === Qt.Key_Up) {
                                    if (currentIndex > 0) {
                                        currentIndex = currentIndex - 1
                                    }
                                    event.accepted = true
                                    return
                                }
                                if (root.isTvActivateButton(event)) {
                                    if (currentIndex >= 0) {
                                        switchStreamQuality((currentStream.availableQualities || [])[currentIndex] || "")
                                        playerQualityModal.close()
                                        playerQualityButton.forceActiveFocus()
                                    }
                                    event.accepted = true
                                    return
                                }
                                if (event.key !== root.hkBack)
                                    return
                                playerQualityModal.close()
                                playerQualityButton.forceActiveFocus()
                                event.accepted = true
                            }
                        }
                    }
                }

                Popup {
                    z: 6
                    id: playerSubtitleModal
                    anchors.centerIn: parent
                    width: Math.min(700, parent.width - 80)
                    height: Math.min(560, parent.height - 80)
                    modal: true
                    focus: true
                    closePolicy: Popup.CloseOnEscape
                    background: Rectangle {
                        color: "#f0151515"
                        radius: 12
                        border.width: 2
                        border.color: "#6fa8df"
                    }
                    onOpened: {
                        playerSubtitleList.currentIndex = selectedSubtitleIndex
                        playerSubtitleList.forceActiveFocus()
                    }

                    ColumnLayout {
                        anchors.fill: parent
                        anchors.margins: 16
                        spacing: 12
                        Text {
                            text: "Выберите субтитры"
                            color: "white"
                            font.pixelSize: 30
                            font.bold: true
                        }
                        ListView {
                            id: playerSubtitleList
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            model: subtitleOptions()
                            clip: true
                            spacing: 8
                            delegate: TvButton {
                                tvPassNavigationKeys: true
                                width: ListView.view.width
                                text: modelData.title || "Субтитры"
                                checkable: true
                                checked: index === playerSubtitleList.currentIndex
                                onClicked: {
                                    selectSubtitle(index)
                                    playerSubtitleModal.close()
                                    subtitleSelectButton.forceActiveFocus()
                                    showPlayerControls()
                                }
                            }
                            Keys.onPressed: function (event) {
                                if (root.tvHotkeysWizardVisible && root.tvWizardApplyKey(event))
                                    return
                                if (event.key === root.hkDown || event.key === Qt.Key_Down) {
                                    if (currentIndex < count - 1) {
                                        currentIndex = currentIndex + 1
                                    }
                                    event.accepted = true
                                    return
                                }
                                if (event.key === root.hkUp || event.key === Qt.Key_Up) {
                                    if (currentIndex > 0) {
                                        currentIndex = currentIndex - 1
                                    }
                                    event.accepted = true
                                    return
                                }
                                if (root.isTvActivateButton(event)) {
                                    if (currentIndex >= 0) {
                                        selectSubtitle(currentIndex)
                                        playerSubtitleModal.close()
                                        subtitleSelectButton.forceActiveFocus()
                                        showPlayerControls()
                                    }
                                    event.accepted = true
                                    return
                                }
                                if (event.key !== root.hkBack && event.key !== Qt.Key_Escape)
                                    return
                                playerSubtitleModal.close()
                                subtitleSelectButton.forceActiveFocus()
                                event.accepted = true
                            }
                        }
                    }
                }

                Text {
                    z: 6
                    id: playerErrorText
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.margins: 18
                    color: "#ff7777"
                    font.pixelSize: 18
                    wrapMode: Text.WordWrap
                }
            }

            function togglePlayPauseFromRemote() {
                if (mediaPlayer.playbackState === MediaPlayer.PlayingState)
                    mediaPlayer.pause()
                else
                    mediaPlayer.play()
                showPlayerControls()
            }

            function _focusInsideItem(focusItem, container) {
                if (!focusItem || !container)
                    return false
                var p = focusItem
                while (p) {
                    if (p === container)
                        return true
                    p = p.parent
                }
                return false
            }

            function playerControlsMenuHasFocus() {
                return playerControlsVisible && _focusInsideItem(root.activeFocusItem, playerControls)
            }

            function playerMenuVolumeStep(up) {
                showPlayerControls()
                if (playerStreamAudio) {
                    var step = 0.06
                    playerStreamAudio.volume = Math.max(0, Math.min(1, playerStreamAudio.volume + (up ? step : -step)))
                }
                if (Qt.platform.os === "linux") {
                    if (up)
                        backend.cecVolumeUp()
                    else
                        backend.cecVolumeDown()
                }
            }

            function playerStreamMenuMoveHorizontal(goRight) {
                var cur = root.activeFocusItem
                if (!_focusInsideItem(cur, playerControls))
                    return false
                var next = null
                if (goRight) {
                    if (cur === playButton)
                        next = previousEpisodeButton.visible ? previousEpisodeButton : playerQualityButton
                    else if (cur === previousEpisodeButton)
                        next = nextEpisodeButton.visible ? nextEpisodeButton : playerQualityButton
                    else if (cur === nextEpisodeButton)
                        next = playerQualityButton
                    else if (cur === playerQualityButton)
                        next = subtitleSelectButton
                    else if (cur === subtitleSelectButton)
                        next = subtitleSmallerButton
                    else if (cur === subtitleSmallerButton)
                        next = subtitleBiggerButton
                    else if (cur === subtitleBiggerButton)
                        next = playButton
                    else
                        return false
                } else {
                    if (cur === playButton)
                        next = subtitleBiggerButton
                    else if (cur === previousEpisodeButton)
                        next = playButton
                    else if (cur === nextEpisodeButton)
                        next = previousEpisodeButton.visible ? previousEpisodeButton : playButton
                    else if (cur === playerQualityButton)
                        next = nextEpisodeButton.visible ? nextEpisodeButton : (previousEpisodeButton.visible ? previousEpisodeButton : playButton)
                    else if (cur === subtitleSelectButton)
                        next = playerQualityButton
                    else if (cur === subtitleSmallerButton)
                        next = subtitleSelectButton
                    else if (cur === subtitleBiggerButton)
                        next = subtitleSmallerButton
                    else
                        return false
                }
                if (!next)
                    return false
                showPlayerControls()
                next.forceActiveFocus()
                return true
            }

            // Linux KEY_OK (352): в Qt часто приходит как Key_Yes; обычная Button на него не реагирует — вызываем click().
            function _isLinuxTvOk(event) {
                return event.key === Qt.Key_Yes || event.nativeScanCode === 352
            }

            function _isConfirmKey(event) {
                return root.isTvActivateButton(event)
            }

            function _tryClickFocusedForTvOk(event) {
                if (!_isLinuxTvOk(event))
                    return false
                var fi = root.activeFocusItem
                if (!fi || typeof fi.click !== "function")
                    return false
                event.accepted = true
                fi.click()
                return true
            }

            // Enter/OK/пробел: пауза только когда фокус не на кнопках панели и не в модалках (иначе перехват ломал активацию).
            Keys.onPressed: function (event) {
                if (root.tvHotkeysWizardVisible && root.tvWizardApplyKey(event))
                    return

                if (_tryClickFocusedForTvOk(event))
                    return

                if (playerQualityModal.opened || playerSubtitleModal.opened) {
                    switch (event.key) {
                    case Qt.Key_MediaPlay:
                    case Qt.Key_MediaPause:
                    case Qt.Key_MediaTogglePlayPause:
                        break
                    default:
                        return
                    }
                }

                switch (event.key) {
                case Qt.Key_MediaPlay:
                case Qt.Key_MediaPause:
                case Qt.Key_MediaTogglePlayPause:
                    event.accepted = true
                    togglePlayPauseFromRemote()
                    return
                default:
                    break
                }

                var keyLeft = event.key === root.hkLeft || event.key === Qt.Key_Left
                var keyRight = event.key === root.hkRight || event.key === Qt.Key_Right
                var keyUp = event.key === root.hkUp || event.key === Qt.Key_Up
                var keyDown = event.key === root.hkDown || event.key === Qt.Key_Down

                if (playerControlsMenuHasFocus()) {
                    if (keyLeft || keyRight) {
                        if (playerStreamMenuMoveHorizontal(keyRight)) {
                            event.accepted = true
                            return
                        }
                    }
                    if (keyUp || keyDown) {
                        playerMenuVolumeStep(keyUp)
                        event.accepted = true
                        return
                    }
                }

                if (keyLeft) {
                    seekBy(-15000)
                    event.accepted = true
                    return
                }
                if (keyRight) {
                    seekBy(15000)
                    event.accepted = true
                    return
                }
                if (keyUp) {
                    showPlayerControls()
                    playButton.forceActiveFocus()
                    event.accepted = true
                    return
                }
                if (keyDown) {
                    showPlayerControls()
                    event.accepted = true
                    return
                }
                if (event.key === root.hkBack || event.key === Qt.Key_Back) {
                    mediaPlayer.stop()
                    stack.currentIndex = 2
                    watchButton.forceActiveFocus()
                    event.accepted = true
                    return
                }

                if (!_isConfirmKey(event))
                    return

                var fi2 = root.activeFocusItem
                if (_focusInsideItem(fi2, playerControls))
                    return
                event.accepted = true
                togglePlayPauseFromRemote()
            }
        }
    }

    Item {
        id: tvHotkeysWizardOverlay
        z: 200000
        anchors.fill: parent
        visible: tvHotkeysWizardVisible

        Rectangle {
            anchors.fill: parent
            color: "#f0111111"
        }

        FocusScope {
            id: tvHotkeysWizardFocus
            anchors.fill: parent
            focus: tvHotkeysWizardVisible

            Keys.onPressed: function (event) {
                if (tvHotkeysWizardVisible)
                    tvWizardApplyKey(event)
            }

            Column {
                anchors.centerIn: parent
                spacing: 22
                width: Math.min(680, parent.parent.width - 80)

                Text {
                    text: "Настройка пульта"
                    color: "white"
                    font.pixelSize: 32
                    font.bold: true
                    width: parent.width
                    horizontalAlignment: Text.AlignHCenter
                }

                Text {
                    text: "Шаг " + (tvWizardStepIndex + 1) + " из " + tvWizardKeyNames().length + " — нажмите клавишу:\n«" + tvWizardStepTitleRu() + "»"
                    color: "#dddddd"
                    font.pixelSize: 22
                    width: parent.width
                    wrapMode: Text.WordWrap
                    horizontalAlignment: Text.AlignHCenter
                }

                Text {
                    visible: tvHotkeysWizardError.length > 0
                    text: tvHotkeysWizardError
                    color: "#ff8888"
                    font.pixelSize: 18
                    width: parent.width
                    wrapMode: Text.WordWrap
                    horizontalAlignment: Text.AlignHCenter
                }
            }
        }

        onVisibleChanged: {
            if (visible) {
                tvWizardStepIndex = 0
                tvWizardPending = ({})
                tvHotkeysWizardError = ""
                Qt.callLater(function () {
                    tvHotkeysWizardFocus.forceActiveFocus()
                })
            }
        }
    }

    Component.onCompleted: {
        reloadTvHotkeysFromBackend()
        if (!backend.tvHotkeysConfigured())
            tvHotkeysWizardVisible = true
        backend.restoreSession()
        Qt.callLater(function () {
            backend.startCompanionServer()
        })
    }
}
