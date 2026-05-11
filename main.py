import json
import os
import re
import subprocess
import sys
import time
import traceback
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from typing import Optional
from urllib.parse import urljoin


def _is_frozen() -> bool:
    return getattr(sys, "frozen", False) and hasattr(sys, "_MEIPASS")


def _bundle_root() -> Path:
    if _is_frozen():
        return Path(sys._MEIPASS)
    return Path(__file__).resolve().parent


def _data_root(bundle: Path) -> Path:
    if _is_frozen():
        xdg = (os.environ.get("XDG_CONFIG_HOME") or "").strip()
        if xdg:
            return Path(xdg) / "rezka-native"
        return Path.home() / ".config" / "rezka-native"
    return bundle


APP_ROOT = _bundle_root()
DATA_ROOT = _data_root(APP_ROOT)


def _launch_log_paths():
    seen = set()
    paths = []

    def add(path: Path) -> None:
        key = str(path)
        if key not in seen:
            seen.add(key)
            paths.append(path)

    env = os.environ.get("REZKA_LOG")
    if env:
        add(Path(env))
    add(DATA_ROOT / "last-launch.log")
    add(Path(os.environ.get("TMPDIR", "/tmp")) / "rezka-native-steam.log")
    return paths


def launch_log(msg: str) -> None:
    line = f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] {msg}"
    wrote = False
    for path in _launch_log_paths():
        try:
            path.parent.mkdir(parents=True, exist_ok=True)
            with open(path, "a", encoding="utf-8") as f:
                f.write(line + "\n")
            wrote = True
        except OSError:
            continue
    if not wrote:
        try:
            sys.stderr.write(line + "\n")
        except OSError:
            pass


# VideoToolbox on macOS can fail on some Rezka H.264 MP4s and cause long
# buffering/stutters. Keep Windows/Linux on Qt's default hardware decoding so
# those platforms can use D3D11VA/DXVA/VAAPI when available.
if sys.platform == "darwin":
    os.environ.setdefault("QT_FFMPEG_DECODING_HW_DEVICE_TYPES", ",")
    os.environ.setdefault("QT_DISABLE_HW_TEXTURES_CONVERSION", "1")

# TV / Pi: крупнее интерфейс (переопределите REZKA_UI_SCALE, напр. 1.0–2.0).
if sys.platform == "linux":
    _scale = (os.environ.get("REZKA_UI_SCALE") or "").strip()
    if _scale:
        os.environ["QT_SCALE_FACTOR"] = _scale
    else:
        os.environ.setdefault("QT_SCALE_FACTOR", "1.4")

import requests
from bs4 import BeautifulSoup

launch_log("importing PySide6 (Qt)...")
try:
    from PySide6.QtCore import QObject, Qt, QUrl, Signal, Slot
    from PySide6.QtGui import QCursor, QDesktopServices, QGuiApplication, QKeySequence, QShortcut
    from PySide6.QtMultimedia import QMediaDevices, QPlaybackOptions
    from PySide6.QtQml import QQmlApplicationEngine
    from PySide6.QtQuick import QQuickWindow
except Exception:
    launch_log("PySide6 import failed:\n" + traceback.format_exc())
    raise

from HdRezkaApi import HdRezkaSession
from HdRezkaApi.types import TVSeries, Movie


ORIGIN = os.getenv("REZKA_ORIGIN", "https://rezka.fi/")
# Каталог приложения (Steam и ярлыки часто задают cwd не там, где лежит проект).
# В AppImage/PyInstaller ресурсы в APP_ROOT (read-only), session/history — в DATA_ROOT.
os.chdir(APP_ROOT)
launch_log(f"APP_ROOT={APP_ROOT} DATA_ROOT={DATA_ROOT} cwd={os.getcwd()}")
HISTORY_FILE = DATA_ROOT / "history.json"
SESSION_FILE = DATA_ROOT / "session.json"
PROGRESS_FILE = DATA_ROOT / "progress.json"

os.environ.setdefault("QT_QUICK_CONTROLS_STYLE", "Basic")


def safe_json(value):
    if value is None or isinstance(value, (str, int, float, bool)):
        return value

    if isinstance(value, dict):
        return {str(k): safe_json(v) for k, v in value.items()}

    if isinstance(value, (list, tuple, set)):
        return [safe_json(v) for v in value]

    if hasattr(value, "__dict__"):
        return safe_json(vars(value))

    return str(value)


def first_url(value):
    if isinstance(value, list):
        return value[0] if value else ""
    return value or ""


def parse_subtitle_timestamp(value):
    value = value.strip().replace(",", ".")
    parts = value.split(":")
    try:
        if len(parts) == 3:
            hours, minutes, seconds = parts
        elif len(parts) == 2:
            hours = 0
            minutes, seconds = parts
        else:
            return 0

        return int((int(hours) * 3600 + int(minutes) * 60 + float(seconds)) * 1000)
    except ValueError:
        return 0


def parse_subtitles(text):
    text = text.replace("\ufeff", "").replace("\r\n", "\n").replace("\r", "\n")
    cues = []
    current = []

    def flush(block):
        lines = [line.strip() for line in block if line.strip()]
        if not lines:
            return

        timing_index = next((i for i, line in enumerate(lines) if "-->" in line), -1)
        if timing_index < 0:
            return

        timing = lines[timing_index]
        start_raw, end_raw = timing.split("-->", 1)
        end_raw = end_raw.split()[0]
        body = "\n".join(lines[timing_index + 1:])
        body = re.sub(r"<br\s*/?>", "\n", body, flags=re.I)
        body = re.sub(r"<[^>]+>", "", body).strip()
        if not body:
            return

        cues.append({
            "start": parse_subtitle_timestamp(start_raw),
            "end": parse_subtitle_timestamp(end_raw),
            "text": body,
        })

    for line in text.split("\n"):
        if line.strip():
            current.append(line)
        else:
            flush(current)
            current = []
    flush(current)

    return cues


def choose_quality(videos, preferred):
    if not videos:
        return "", ""

    keys = list(videos.keys())
    preferred = (preferred or "").strip()

    if preferred and preferred.lower() != "auto":
        for key in keys:
            if preferred == key or preferred in key:
                return key, first_url(videos[key])

    def resolution_number(key):
        match = re.search(r"(\d+)", key)
        return int(match.group(1)) if match else 0

    fast_start = [key for key in keys if resolution_number(key) and resolution_number(key) <= 480]
    if fast_start:
        key = sorted(fast_start, key=resolution_number)[-1]
        return key, first_url(videos[key])

    stable = [key for key in keys if resolution_number(key) and resolution_number(key) <= 720]
    if stable:
        key = sorted(stable, key=resolution_number)[-1]
        return key, first_url(videos[key])

    key = sorted(keys, key=resolution_number)[0]
    return key, first_url(videos[key])


def parse_inline_items(html):
    soup = BeautifulSoup(html, "html.parser")
    items = []

    for item in soup.select(".b-content__inline_item"):
        link = item.select_one(".b-content__inline_item-link a[href]")
        cover = item.select_one(".b-content__inline_item-cover img")
        if not link:
            continue

        title = link.get_text(" ", strip=True)
        url = link.get("href", "")
        image = cover.get("src", "") if cover else ""
        info = ""

        cat = item.select_one(".cat")
        if cat:
            info = cat.get_text(" ", strip=True)

        misc = item.select_one(".misc")
        if misc:
            misc_text = misc.get_text(" ", strip=True)
            info = f"{info} {misc_text}".strip()

        items.append({
            "id": url,
            "title": title,
            "url": url,
            "play_url": url,
            "image": image,
            "info": info,
            "date": "",
            "year": "",
        })

    return items


def parse_resume_position(*values):
    text = " ".join(str(value or "") for value in values)

    for pattern in (r"(\d{1,2}):(\d{2}):(\d{2})", r"(\d{1,2}):(\d{2})"):
        match = re.search(pattern, text)
        if not match:
            continue

        parts = [int(part) for part in match.groups()]
        if len(parts) == 3:
            hours, minutes, seconds = parts
        else:
            hours = 0
            minutes, seconds = parts

        return ((hours * 3600) + (minutes * 60) + seconds) * 1000

    return 0


def parse_resume_seconds(value):
    try:
        seconds = int(float(str(value or "").strip()))
    except ValueError:
        return 0

    if seconds <= 0:
        return 0

    if seconds > 24 * 60 * 60:
        return seconds

    return seconds * 1000


def find_resume_position(row, *fallback_values):
    resume_position = parse_resume_position(*fallback_values)
    if resume_position > 0:
        return resume_position

    time_selectors = (
        '[data-current_time]',
        '[data-current-time]',
        '[data-time]',
        '[data-duration]',
        'input[name="current_time"]',
        'input[name="time"]',
        'input[name="watching_time"]',
        'input[name="progress"]',
    )

    for node in row.select(", ".join(time_selectors)):
        for attr in (
            "data-current_time",
            "data-current-time",
            "data-time",
            "data-duration",
            "value",
        ):
            resume_position = parse_resume_seconds(node.get(attr))
            if resume_position > 0:
                return resume_position

    for attr in (
        "data-current_time",
        "data-current-time",
        "data-time",
        "data-duration",
        "data-watch-time",
        "data-progress",
    ):
        resume_position = parse_resume_seconds(row.get(attr))
        if resume_position > 0:
            return resume_position

    return 0


def parse_continue_info(value):
    text = str(value or "")
    season = ""
    episode = ""
    translator_name = ""

    match = re.search(r"(\d+)\s*сезон\s+(\d+)\s*сер", text, flags=re.I)
    if match:
        season = match.group(1)
        episode = match.group(2)

    translator_match = re.search(r"\(([^)]+)\)", text)
    if translator_match:
        translator_name = translator_match.group(1).strip()

    return season, episode, translator_name


def content_id_from_url(url):
    match = re.search(r"/(\d+)-[^/]+\.html", str(url or ""))
    return match.group(1) if match else ""

def normalize_category(value):
    text = str(value or "").lower()
    if "category.series" in text or text.endswith("series"):
        return "Сериал"
    if "category.film" in text or text.endswith("film"):
        return "Фильм"
    if "category.cartoon" in text or text.endswith("cartoon"):
        return "Мультфильм"
    if "category.anime" in text or text.endswith("anime"):
        return "Аниме"
    return str(value or "")

def _rating_from_rate_span(span):
    if not span:
        return ""
    bold = span.find(class_="bold")
    value = bold.get_text(strip=True) if bold else ""
    votes = span.find("i")
    votes_t = votes.get_text(strip=True) if votes else ""
    if not value:
        return ""
    return f"{value} {votes_t}".strip() if votes_t else value


def _person_names_from_holder(holder, itemprop_role):
    if not holder:
        return ""
    names = []
    for node in holder.find_all(attrs={"itemprop": itemprop_role}):
        name_el = node.find(attrs={"itemprop": "name"})
        if name_el:
            text = name_el.get_text(strip=True)
            if text:
                names.append(text)
    return ", ".join(names)


def parse_people_and_ratings(soup):
    result = {
        "director": "",
        "actors": "",
        "externalRatings": {
            "kinopoisk": "",
            "imdb": "",
        },
    }

    info = soup.find("table", class_="b-post__info")
    if not info:
        return result

    imdb_span = info.select_one("span.b-post__info_rates.imdb")
    kp_span = info.select_one("span.b-post__info_rates.kp")
    result["externalRatings"]["imdb"] = _rating_from_rate_span(imdb_span)
    result["externalRatings"]["kinopoisk"] = _rating_from_rate_span(kp_span)

    for row in info.find_all("tr"):
        tds = row.find_all("td", recursive=False)

        wide = row.find("td", attrs={"colspan": "2"})
        if wide:
            holder = wide.find("div", class_="persons-list-holder")
            if holder and holder.find(attrs={"itemprop": "actor"}):
                actors = _person_names_from_holder(holder, "actor")
                if actors:
                    result["actors"] = actors
            continue

        if len(tds) < 2:
            continue

        label_cell, value_cell = tds[0], tds[-1]
        label = re.sub(r"\s+", " ", label_cell.get_text(" ", strip=True)).lower()
        holder = value_cell.find("div", class_="persons-list-holder")

        if holder and holder.find(attrs={"itemprop": "director"}):
            directors = _person_names_from_holder(holder, "director")
            if directors:
                result["director"] = directors
            continue

        if "режиссер" in label or "режиссёр" in label:
            directors = _person_names_from_holder(holder, "director") if holder else ""
            if not directors:
                value_links = [
                    re.sub(r"\s+", " ", a.get_text(" ", strip=True))
                    for a in value_cell.find_all("a")
                ]
                directors = ", ".join([v for v in value_links if v])
            if directors:
                result["director"] = directors

    return result


def _git_run(*args, cwd=None, timeout=180):
    try:
        return subprocess.run(
            ["git", *args],
            cwd=cwd or APP_ROOT,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
    except FileNotFoundError:
        return subprocess.CompletedProcess(
            ["git", *args], 127, "", "git: команда не найдена"
        )
    except subprocess.TimeoutExpired:
        return subprocess.CompletedProcess(["git", *args], 124, "", "git: таймаут")


def _git_short_rev(rev, cwd=None):
    r = _git_run("rev-parse", "--short", rev, cwd=cwd, timeout=30)
    if r.returncode != 0:
        return ""
    return (r.stdout or "").strip()


def _github_repo_for_updates() -> Optional[str]:
    raw = os.environ.get("REZKA_GITHUB_REPO")
    if raw is not None:
        r = raw.strip()
        if not r:
            return None
        return r
    return "xpoison52/rezka"


def _normalize_version_label(value: str) -> str:
    s = (value or "").strip().lstrip("vV")
    if not s:
        return "0.0.0"
    s = s.split("-")[0].split("+")[0].strip()
    return s or "0.0.0"


def _version_tuple(value: str) -> tuple:
    base = _normalize_version_label(value)
    parts: list[int] = []
    for seg in base.split("."):
        m = re.match(r"^(\d+)", seg.strip())
        parts.append(int(m.group(1)) if m else 0)
    if not parts:
        parts = [0]
    return tuple(parts)


def _local_app_version() -> str:
    env = (os.environ.get("REZKA_APP_VERSION") or "").strip()
    if env:
        return env
    vf = APP_ROOT / "app-version.txt"
    if vf.exists():
        try:
            line = vf.read_text(encoding="utf-8", errors="replace").strip().splitlines()
            if line and line[0].strip():
                return line[0].strip()
        except OSError:
            pass
    if (APP_ROOT / ".git").is_dir():
        r = _git_run("describe", "--tags", "--abbrev=0", timeout=30)
        if r.returncode == 0 and (r.stdout or "").strip():
            return (r.stdout or "").strip()
    return "0.0.0"


def _emit_app_update(backend, payload):
    backend.appUpdateChanged.emit(json.dumps(payload, ensure_ascii=False))


class Backend(QObject):
    loginChanged = Signal(bool)
    historyChanged = Signal(str)
    detailsChanged = Signal(str)
    episodesChanged = Signal(str)
    streamChanged = Signal(str)
    subtitlesChanged = Signal(str)
    errorChanged = Signal(str)
    loadingChanged = Signal(str)
    appUpdateChanged = Signal(str)
    restartRequested = Signal()
    openReleaseUrl = Signal(str)

    def __init__(self):
        super().__init__()
        self.session = None
        self.current_rezka = None
        self.current_stream_state = {}
        self.executor = ThreadPoolExecutor(max_workers=4)
        self.details_request_id = 0
        self.stream_request_id = 0
        self._update_remote = (os.environ.get("REZKA_GIT_REMOTE") or "origin").strip() or "origin"
        self._update_branch = (os.environ.get("REZKA_GIT_BRANCH") or "").strip()
        self._update_download_url = ""
        self._update_release_page_url = ""
        self.restartRequested.connect(self._restart_process, Qt.ConnectionType.QueuedConnection)

    def emit_json(self, signal, data):
        signal.emit(json.dumps(safe_json(data), ensure_ascii=False))

    def run_async(self, fn):
        self.executor.submit(fn)

    def save_session(self):
        if not self.session:
            return

        data = {
            "origin": ORIGIN,
            "cookies": getattr(self.session, "cookies", {}) or {},
        }
        SESSION_FILE.write_text(json.dumps(data, ensure_ascii=False, indent=2), "utf-8")

    def load_local_progress(self):
        if not PROGRESS_FILE.exists():
            return {}

        try:
            return json.loads(PROGRESS_FILE.read_text("utf-8"))
        except Exception:
            return {}

    def save_local_progress(self, payload):
        progress = self.load_local_progress()
        key = ":".join([
            str(payload.get("content_id", "")),
            str(payload.get("translator_id", "")),
            str(payload.get("season", "0")),
            str(payload.get("episode", "0")),
        ])

        progress[key] = payload
        progress[f"content:{payload.get('content_id', '')}"] = payload
        PROGRESS_FILE.write_text(json.dumps(progress, ensure_ascii=False, indent=2), "utf-8")

    def find_local_progress(self, content_id, translator_id="", season="0", episode="0"):
        progress = self.load_local_progress()
        keys = [
            ":".join([str(content_id), str(translator_id), str(season or "0"), str(episode or "0")]),
            ":".join([str(content_id), "", str(season or "0"), str(episode or "0")]),
            f"content:{content_id}",
        ]

        for key in keys:
            item = progress.get(key)
            if item:
                return item

        return {}

    @Slot()
    def restoreSession(self):
        if not SESSION_FILE.exists():
            return

        try:
            data = json.loads(SESSION_FILE.read_text("utf-8"))
            if data.get("origin") != ORIGIN:
                return

            cookies = data.get("cookies") or {}
            if not cookies:
                return

            self.session = HdRezkaSession(ORIGIN, cookies=cookies)
            self.loginChanged.emit(True)
            self.loadContinue()
        except Exception:
            try:
                SESSION_FILE.unlink()
            except Exception:
                pass

    @Slot(str, str)
    def login(self, email, password):
        try:
            self.errorChanged.emit("")
            print("Using origin:", ORIGIN)

            session = HdRezkaSession(ORIGIN)
            ok = session.login(email, password)

            if not ok:
                self.errorChanged.emit("Не удалось войти")
                self.loginChanged.emit(False)
                return

            self.session = session
            self.save_session()
            self.loginChanged.emit(True)
            self.loadContinue()

        except Exception as e:
            self.errorChanged.emit(f"Ошибка входа: {e}")
            self.loginChanged.emit(False)

    @Slot()
    def loadContinue(self):
        if self.session is None:
            self.errorChanged.emit("Сначала войдите")
            return

        self.loadingChanged.emit("Загружаем историю...")

        def work():
            try:
                cookies = getattr(self.session, "cookies", None)
                headers = getattr(self.session, "HEADERS", {})

                url = urljoin(ORIGIN, "/continue/")
                r = requests.get(url, cookies=cookies, headers=headers, timeout=20)
                r.raise_for_status()

                soup = BeautifulSoup(r.text, "html.parser")
                items = []

                rows = soup.select('#videosaves-list .b-videosaves__list_item[id^="videosave-"]')

                for row in rows:
                    title_cell = row.select_one(".td.title")
                    info_cell = row.select_one(".td.info")
                    date_cell = row.select_one(".td.date")
                    link = row.select_one(".td.title a[href]")

                    if not link:
                        continue

                    item_id = row.get("id", "").replace("videosave-", "")
                    title = link.get_text(" ", strip=True)
                    href = link.get("href", "")
                    cover = link.get("data-cover_url", "")
                    year = ""

                    small = title_cell.select_one("small") if title_cell else None
                    if small:
                        year = small.get_text(" ", strip=True)

                    info_text = info_cell.get_text(" ", strip=True) if info_cell else ""
                    date_text = date_cell.get_text(" ", strip=True) if date_cell else ""

                    continue_link = row.select_one(".td.info a.new-episode[href]")
                    play_url = continue_link.get("href") if continue_link else href
                    resume_season, resume_episode, resume_translator = parse_continue_info(info_text)
                    content_id = content_id_from_url(href)
                    resume_position = find_resume_position(
                        row,
                        info_text,
                        date_text,
                        row.get_text(" ", strip=True),
                        row.get("data-current_time", ""),
                        row.get("data-time", ""),
                        row.get("data-current-time", ""),
                    )
                    local_progress = self.find_local_progress(
                        content_id,
                        "",
                        resume_season or "0",
                        resume_episode or "0",
                    )
                    if resume_position <= 0:
                        resume_position = int(local_progress.get("position", 0) or 0)

                    items.append({
                        "id": item_id,
                        "contentId": content_id,
                        "title": title,
                        "year": year,
                        "info": info_text,
                        "date": date_text,
                        "url": href,
                        "play_url": play_url,
                        "image": cover,
                        "resumePosition": resume_position,
                        "resumeSeason": resume_season,
                        "resumeEpisode": resume_episode,
                        "resumeTranslatorName": resume_translator,
                        "resumeTranslatorId": str(local_progress.get("translator_id", "") or ""),
                        "resumeQuality": str(local_progress.get("quality", "") or ""),
                    })

                self.emit_json(self.historyChanged, items)
                self.loadingChanged.emit("")

            except Exception as e:
                self.loadingChanged.emit("")
                self.errorChanged.emit(f"Не удалось загрузить /continue/: {e}")

        self.run_async(work)

    @Slot(str)
    def search(self, query):
        if self.session is None:
            self.errorChanged.emit("Сначала войдите")
            return

        query = query.strip()
        if not query:
            self.errorChanged.emit("Введите запрос")
            return

        self.loadingChanged.emit("Ищем...")

        def work():
            try:
                result = self.session.search(query, find_all=True)
                items = result[0] or []
                normalized = []
                for item in items:
                    normalized.append({
                        "id": item.get("url", ""),
                        "title": item.get("title", ""),
                        "url": item.get("url", ""),
                        "play_url": item.get("url", ""),
                        "image": item.get("image", ""),
                        "info": str(item.get("category", "") or ""),
                        "date": "",
                        "year": "",
                    })

                self.emit_json(self.historyChanged, normalized)
                self.loadingChanged.emit("")
            except Exception as e:
                self.loadingChanged.emit("")
                self.errorChanged.emit(f"Не удалось выполнить поиск: {e}")

        self.run_async(work)

    def build_details_payload(self, rezka, url, include_episodes=False):
        parsed_info = parse_people_and_ratings(rezka.soup)
        rating = None
        if getattr(rezka, "rating", None):
            rating = {
                "value": getattr(rezka.rating, "value", None),
                "votes": getattr(rezka.rating, "votes", None),
            }

        is_series = (
            getattr(rezka, "type", None) == TVSeries
            or str(getattr(rezka, "type", "")) == "tv_series"
        )

        episodes = []
        if include_episodes and is_series:
            episodes = getattr(rezka, "episodesInfo", []) or []

        return {
            "id": str(getattr(rezka, "id", "")),
            "name": getattr(rezka, "name", ""),
            "description": getattr(rezka, "description", ""),
            "type": str(getattr(rezka, "type", "")),
            "category": normalize_category(getattr(rezka, "category", "")),
            "thumbnail": getattr(rezka, "thumbnail", ""),
            "thumbnailHQ": getattr(rezka, "thumbnailHQ", "") or getattr(rezka, "thumbnail", ""),
            "rating": rating,
            "externalRatings": parsed_info["externalRatings"],
            "director": parsed_info["director"],
            "actors": parsed_info["actors"],
            "translators": getattr(rezka, "translators", {}) or {},
            "translators_names": getattr(rezka, "translators_names", {}) or {},
            "seriesInfo": getattr(rezka, "seriesInfo", {}) if include_episodes and is_series else {},
            "episodesInfo": episodes,
            "episodesLoading": is_series and not include_episodes,
            "otherParts": getattr(rezka, "otherParts", []) or [],
            "url": url,
            "isSeries": is_series,
            "isMovie": getattr(rezka, "type", None) == Movie or str(getattr(rezka, "type", "")) == "movie",
        }

    @Slot(str)
    def loadDetails(self, url):
        if self.session is None:
            self.errorChanged.emit("Сначала войдите")
            return

        self.details_request_id += 1
        request_id = self.details_request_id
        self.errorChanged.emit("")
        self.loadingChanged.emit("Открываем карточку...")

        def work():
            try:
                rezka = self.session.get(url)
                if hasattr(rezka, "ok") and not rezka.ok:
                    raise rezka.exception
                if request_id != self.details_request_id:
                    return

                self.current_rezka = rezka
                data = self.build_details_payload(rezka, url, include_episodes=False)
                self.emit_json(self.detailsChanged, data)
                self.loadingChanged.emit("Догружаем сезоны и серии..." if data["isSeries"] else "")

                if data["isSeries"]:
                    episodes = getattr(rezka, "episodesInfo", []) or []
                    if request_id == self.details_request_id:
                        self.emit_json(self.episodesChanged, {
                            "url": url,
                            "episodesInfo": episodes,
                            "seriesInfo": getattr(rezka, "seriesInfo", {}) or {},
                        })
                        self.loadingChanged.emit("")

            except Exception as e:
                if request_id == self.details_request_id:
                    self.loadingChanged.emit("")
                    self.errorChanged.emit(f"Не удалось загрузить детали: {e}")

        self.run_async(work)

    @Slot(str, str, str, str)
    def loadStream(self, season, episode, quality, translation):
        if self.current_rezka is None:
            self.errorChanged.emit("Сначала откройте фильм")
            return

        self.stream_request_id += 1
        request_id = self.stream_request_id
        rezka = self.current_rezka
        self.errorChanged.emit("")
        self.loadingChanged.emit("Получаем видеопоток...")

        def work():
            try:
                translation_value = translation.strip() or None
                quality_value = quality.strip() or "Auto"

                is_series = (
                    getattr(rezka, "type", None) == TVSeries
                    or str(getattr(rezka, "type", "")) == "tv_series"
                )

                if is_series:
                    stream = rezka.getStream(
                        season.strip(),
                        episode.strip(),
                        translation=translation_value,
                    )
                else:
                    stream = rezka.getStream(translation=translation_value)

                videos = {}
                for q, urls in getattr(stream, "videos", {}).items():
                    videos[str(q)] = urls

                selected_quality, selected = choose_quality(videos, quality_value)

                subtitles = {}
                subs = getattr(stream, "subtitles", None)
                if subs and getattr(subs, "subtitles", None):
                    for key, value in subs.subtitles.items():
                        subtitles[str(key)] = {
                            "title": value.get("title", str(key)),
                            "url": value.get("link", ""),
                        }

                payload = {
                    "videoUrl": selected,
                    "quality": selected_quality,
                    "availableQualities": list(videos.keys()),
                    "videos": videos,
                    "subtitles": subtitles,
                    "translator_id": getattr(stream, "translator_id", translation_value),
                    "season": getattr(stream, "season", season),
                    "episode": getattr(stream, "episode", episode),
                    "name": getattr(stream, "name", getattr(rezka, "name", "")),
                    "contentUrl": getattr(rezka, "url", ""),
                    "contentId": str(getattr(rezka, "id", "")),
                }

                if request_id == self.stream_request_id:
                    self.current_stream_state = payload
                    self.emit_json(self.streamChanged, payload)
                    self.loadingChanged.emit("")

            except Exception as e:
                if request_id == self.stream_request_id:
                    self.loadingChanged.emit("")
                    self.errorChanged.emit(f"Не удалось получить поток: {e}")

        self.run_async(work)

    @Slot(str)
    def loadSubtitles(self, url):
        if not url:
            self.emit_json(self.subtitlesChanged, [])
            return

        self.loadingChanged.emit("Загружаем субтитры...")

        def work():
            try:
                headers = getattr(self.session, "HEADERS", {}) if self.session else {}
                cookies = getattr(self.session, "cookies", None) if self.session else None
                response = requests.get(url, headers=headers, cookies=cookies, timeout=15)
                response.raise_for_status()
                response.encoding = response.encoding or "utf-8"
                cues = parse_subtitles(response.text)
                self.emit_json(self.subtitlesChanged, cues)
                self.loadingChanged.emit("")
            except Exception as e:
                self.loadingChanged.emit("")
                self.errorChanged.emit(f"Не удалось загрузить субтитры: {e}")

        self.run_async(work)

    @Slot(int, int, int)
    def saveWatchProgress(self, position_ms, duration_ms, last_position_ms):
        if self.current_rezka is None or self.session is None:
            return

        rezka = self.current_rezka
        stream_state = self.current_stream_state or {}
        position = max(0, int(position_ms / 1000))
        duration = max(0, int(duration_ms / 1000))
        post_id = str(stream_state.get("contentId") or getattr(rezka, "id", "") or "")

        if not post_id:
            return

        def work():
            try:
                referer = stream_state.get("contentUrl") or getattr(rezka, "url", "") or ORIGIN
                headers = dict(getattr(self.session, "HEADERS", {}) or {})
                headers.update({
                    "Origin": ORIGIN.rstrip("/"),
                    "Referer": referer,
                    "X-Requested-With": "XMLHttpRequest",
                    "Content-Type": "application/x-www-form-urlencoded; charset=UTF-8",
                })
                cookies = getattr(self.session, "cookies", None)
                translator_id = str(stream_state.get("translator_id") or "")
                season = str(stream_state.get("season") or "0")
                episode = str(stream_state.get("episode") or "0")

                common_payload = {"id": post_id}
                if translator_id:
                    common_payload["translator_id"] = translator_id

                timestamp = int(time.time() * 1000)
                watching_payload = {"action": "update_rg", **common_payload}
                watching_response = requests.post(
                    urljoin(ORIGIN, f"/ajax/send_watching/?t={timestamp}"),
                    data=watching_payload,
                    headers=headers,
                    cookies=cookies,
                    timeout=8,
                )
                print(
                    "send_watching",
                    watching_payload,
                    watching_response.status_code,
                    watching_response.text[:120],
                    flush=True,
                )

                save_payload = {
                    "post_id": post_id,
                    "season": season,
                    "episode": episode,
                    "current_time": position,
                    "duration": duration,
                }
                if translator_id:
                    save_payload["translator_id"] = translator_id

                self.save_local_progress({
                    "content_id": post_id,
                    "translator_id": translator_id,
                    "season": season,
                    "episode": episode,
                    "position": position_ms,
                    "duration": duration_ms,
                    "quality": str(stream_state.get("quality", "") or ""),
                    "updated_at": int(time.time()),
                })

                save_response = requests.post(
                    urljoin(ORIGIN, f"/ajax/send_save/?t={timestamp + 1}"),
                    data=save_payload,
                    headers=headers,
                    cookies=cookies,
                    timeout=8,
                )
                print(
                    "send_save",
                    save_payload,
                    save_response.status_code,
                    save_response.text[:120],
                    flush=True,
                )
            except Exception as e:
                print("watch progress error", e, flush=True)

        self.run_async(work)

    @Slot()
    def loadHistory(self):
        if not HISTORY_FILE.exists():
            self.historyChanged.emit("[]")
            return

        try:
            self.historyChanged.emit(HISTORY_FILE.read_text("utf-8"))
        except Exception as e:
            self.errorChanged.emit(f"Не удалось прочитать history.json: {e}")

    def _git_branch_resolved(self):
        if self._update_branch:
            return self._update_branch
        r = _git_run("rev-parse", "--abbrev-ref", "HEAD")
        if r.returncode != 0:
            return ""
        return (r.stdout or "").strip()

    @Slot()
    def _restart_process(self):
        if _is_frozen():
            argv = [sys.executable, *sys.argv[1:]]
        else:
            script = APP_ROOT / "main.py"
            argv = [sys.executable, str(script), *sys.argv[1:]]
        launch_log(f"restart: exec {argv}")
        try:
            os.execv(sys.executable, argv)
        except OSError as e:
            launch_log(f"restart exec failed: {e}\n{traceback.format_exc()}")
            self.errorChanged.emit(f"Не удалось перезапустить приложение: {e}")

    def _git_check_for_updates(self):
        if not (APP_ROOT / ".git").is_dir():
            _emit_app_update(self, {
                "status": "error",
                "message": "Нет папки .git — клонируйте репозиторий или уберите REZKA_UPDATES_VIA_GIT.",
            })
            return

        st = _git_run("status", "--porcelain")
        if st.returncode != 0:
            _emit_app_update(self, {
                "status": "error",
                "message": f"git status не удался: {(st.stderr or st.stdout or '').strip()}",
            })
            return
        if (st.stdout or "").strip():
            _emit_app_update(self, {
                "status": "error",
                "message": "В каталоге проекта есть незакоммиченные изменения. Сохраните или откатите их, затем выполните git pull вручную.",
            })
            return

        branch = self._git_branch_resolved()
        if not branch or branch == "HEAD":
            _emit_app_update(self, {
                "status": "error",
                "message": "Не удалось определить ветку git (detached HEAD?). Задайте REZKA_GIT_BRANCH.",
            })
            return

        fetch = _git_run("fetch", self._update_remote, "--prune", timeout=120)
        if fetch.returncode != 0:
            err = (fetch.stderr or fetch.stdout or "").strip()
            _emit_app_update(self, {
                "status": "error",
                "message": f"git fetch не удался: {err or 'неизвестная ошибка'}",
            })
            return

        upstream = f"{self._update_remote}/{branch}"
        rh = _git_run("rev-parse", upstream)
        if rh.returncode != 0:
            _emit_app_update(self, {
                "status": "error",
                "message": f"Нет ветки {upstream} после fetch. Проверьте remote и имя ветки (REZKA_GIT_BRANCH).",
            })
            return

        cnt = _git_run("rev-list", "--count", f"HEAD..{upstream}")
        if cnt.returncode != 0:
            _emit_app_update(self, {
                "status": "error",
                "message": f"Не сравнить версии: {(cnt.stderr or '').strip()}",
            })
            return
        try:
            behind = int((cnt.stdout or "0").strip() or 0)
        except ValueError:
            behind = 0

        local_s = _git_short_rev("HEAD")
        remote_s = _git_short_rev(upstream)

        if behind == 0:
            _emit_app_update(self, {
                "status": "current",
                "message": f"У вас последняя версия ({local_s or '—'}).",
                "localShort": local_s,
                "remoteShort": remote_s,
                "commitsBehind": 0,
                "channel": "git",
            })
        else:
            _emit_app_update(self, {
                "status": "behind",
                "message": f"Доступно обновление: {behind} комм.",
                "localShort": local_s,
                "remoteShort": remote_s,
                "commitsBehind": behind,
                "channel": "git",
            })

    def _github_check_for_updates(self, repo: str):
        local_raw = _local_app_version()
        local_label = _normalize_version_label(local_raw)
        api = f"https://api.github.com/repos/{repo}/releases/latest"
        try:
            r = requests.get(
                api,
                headers={
                    "Accept": "application/vnd.github+json",
                    "X-GitHub-Api-Version": "2022-11-28",
                    "User-Agent": "rezka-native",
                },
                timeout=25,
            )
        except requests.RequestException as e:
            _emit_app_update(self, {
                "status": "error",
                "message": f"Не удалось связаться с GitHub: {e}",
            })
            return

        if r.status_code == 404:
            _emit_app_update(self, {
                "status": "error",
                "message": "На GitHub нет опубликованных релизов (latest).",
            })
            return
        if r.status_code != 200:
            _emit_app_update(self, {
                "status": "error",
                "message": f"GitHub API: HTTP {r.status_code}",
            })
            return

        try:
            data = r.json()
        except ValueError:
            _emit_app_update(self, {
                "status": "error",
                "message": "Некорректный ответ GitHub API.",
            })
            return

        tag = (data.get("tag_name") or "").strip()
        if not tag:
            _emit_app_update(self, {
                "status": "error",
                "message": "В ответе GitHub нет tag_name.",
            })
            return

        remote_label = _normalize_version_label(tag)
        page_url = (data.get("html_url") or "").strip()
        download_url = ""
        for asset in data.get("assets") or []:
            name = (asset.get("name") or "").lower()
            if name.endswith(".appimage"):
                download_url = (asset.get("browser_download_url") or "").strip()
                break

        if _version_tuple(remote_label) <= _version_tuple(local_label):
            _emit_app_update(self, {
                "status": "current",
                "message": f"Установлена последняя версия ({local_label}).",
                "localShort": local_label,
                "remoteShort": remote_label,
                "commitsBehind": 0,
                "channel": "github",
            })
            return

        self._update_release_page_url = page_url
        self._update_download_url = download_url
        extra = ""
        if download_url:
            extra = " Нажмите кнопку — откроется загрузка AppImage."
        elif page_url:
            extra = " Нажмите кнопку — откроется страница релиза."
        _emit_app_update(self, {
            "status": "behind",
            "message": f"Доступен релиз {remote_label} (у вас {local_label}).{extra}",
            "localShort": local_label,
            "remoteShort": remote_label,
            "commitsBehind": 0,
            "channel": "github",
        })

    @Slot()
    def checkForAppUpdate(self):
        def work():
            self._update_download_url = ""
            self._update_release_page_url = ""
            _emit_app_update(self, {"status": "checking", "message": ""})

            use_git = (os.environ.get("REZKA_UPDATES_VIA_GIT") or "").strip() == "1"
            repo = _github_repo_for_updates()

            if use_git:
                self._git_check_for_updates()
                return

            if repo:
                self._github_check_for_updates(repo)
                return

            if (APP_ROOT / ".git").is_dir():
                self._git_check_for_updates()
                return

            _emit_app_update(self, {
                "status": "error",
                "message": "Задайте репозиторий: REZKA_GITHUB_REPO=владелец/имя (или клонируйте git и включите REZKA_UPDATES_VIA_GIT=1).",
            })

        self.run_async(work)

    @Slot()
    def applyAppUpdateAndRestart(self):
        def work():
            dl = self._update_download_url.strip()
            page = self._update_release_page_url.strip()
            if dl or page:
                url = dl or page
                self._update_download_url = ""
                self._update_release_page_url = ""
                self.openReleaseUrl.emit(url)
                return

            branch = self._git_branch_resolved()
            if not branch:
                _emit_app_update(self, {
                    "status": "error",
                    "message": "Не удалось определить ветку для обновления.",
                })
                return

            _emit_app_update(self, {"status": "pulling", "message": "Скачиваем и обновляем зависимости…"})

            pull = _git_run(
                "pull", "--ff-only", self._update_remote, branch, timeout=180
            )
            if pull.returncode != 0:
                err = (pull.stderr or pull.stdout or "").strip()
                _emit_app_update(self, {
                    "status": "error",
                    "message": f"git pull не удался (нужен ручной merge?): {err[-800:]}" if err else "git pull не удался.",
                })
                return

            pip = subprocess.run(
                [
                    sys.executable,
                    "-m",
                    "pip",
                    "install",
                    "-q",
                    "-r",
                    str(APP_ROOT / "requirements.txt"),
                ],
                cwd=APP_ROOT,
                capture_output=True,
                text=True,
                timeout=600,
            )
            if pip.returncode != 0:
                tail = (pip.stderr or pip.stdout or "")[-800:]
                _emit_app_update(self, {
                    "status": "error",
                    "message": f"pip install не удался: {tail}" if tail else "pip install не удался.",
                })
                return

            chk = subprocess.run(
                [sys.executable, "-m", "py_compile", str(APP_ROOT / "main.py")],
                cwd=APP_ROOT,
                capture_output=True,
                text=True,
                timeout=30,
            )
            if chk.returncode != 0:
                err = (chk.stderr or chk.stdout or "").strip()
                _emit_app_update(self, {
                    "status": "error",
                    "message": "После обновления main.py не проходит проверку — перезапуск отменён, исправьте вручную.\n"
                    + (err[-600:] if err else ""),
                })
                return

            _emit_app_update(self, {"status": "restarting", "message": "Перезапуск…"})
            self.restartRequested.emit()

        self.run_async(work)

    @Slot()
    def quit(self):
        QGuiApplication.quit()

    def _cec_command(self, command: bytes) -> None:
        if sys.platform != "linux" or os.environ.get("REZKA_CEC", "1") != "1":
            return
        argv = ["cec-client", "-s", "-d", "1"]
        extra = (os.environ.get("REZKA_CEC_CLIENT_ARGS") or "").strip()
        if extra:
            argv.extend(extra.split())
        try:
            subprocess.run(
                argv,
                input=command,
                capture_output=True,
                timeout=4,
            )
        except FileNotFoundError:
            launch_log("cec-client не найден (sudo apt install cec-utils)")
        except Exception as e:
            launch_log(f"cec-client: {e}")

    @Slot()
    def cecVolumeUp(self):
        def work():
            self._cec_command(b"volup\n")

        self.run_async(work)

    @Slot()
    def cecVolumeDown(self):
        def work():
            self._cec_command(b"voldown\n")

        self.run_async(work)

    @Slot()
    def cecVolumeMute(self):
        def work():
            self._cec_command(b"mute\n")

        self.run_async(work)

    @Slot(QObject)
    def configureMediaPlayer(self, media_player):
        if not media_player:
            return

        playback_options = QPlaybackOptions()
        playback_options.setPlaybackIntent(QPlaybackOptions.PlaybackIntent.LowLatencyStreaming)
        playback_options.setProbeSize(32 * 1024)
        media_player.setPlaybackOptions(playback_options)

        audio_out = media_player.audioOutput()
        if not audio_out:
            return

        try:
            audio_out.setVolume(1.0)
        except Exception:
            pass

        devices = list(QMediaDevices.audioOutputs())
        if os.environ.get("REZKA_AUDIO_DEBUG") == "1":
            for dev in devices:
                launch_log(f"audio output candidate id={dev.id()!r} desc={dev.description()!r}")

        preferred = (os.environ.get("REZKA_AUDIO_DEVICE") or "").strip()

        def pick_device():
            if preferred:
                pl = preferred.lower()
                for dev in devices:
                    if preferred == dev.id() or pl in dev.description().lower():
                        return dev
            if sys.platform == "linux":
                for dev in devices:
                    desc = dev.description().lower()
                    if "hdmi" in desc or "vc4hdmi" in desc or "vc4-hdmi" in desc:
                        return dev
            return None

        chosen = pick_device()
        if chosen:
            try:
                audio_out.setDevice(chosen)
                launch_log(f"audio output: {chosen.description()!r} ({chosen.id()!r})")
            except Exception as e:
                launch_log(f"audio setDevice failed: {e}")


def main() -> int:
    if _is_frozen():
        try:
            DATA_ROOT.mkdir(parents=True, exist_ok=True)
        except OSError:
            pass

    launch_log(
        f"env DISPLAY={os.environ.get('DISPLAY')!r} "
        f"WAYLAND_DISPLAY={os.environ.get('WAYLAND_DISPLAY')!r} "
        f"QT_QPA_PLATFORM={os.environ.get('QT_QPA_PLATFORM')!r} "
        f"XDG_SESSION_TYPE={os.environ.get('XDG_SESSION_TYPE')!r}"
    )
    launch_log(f"python {sys.version.split()[0]} executable={sys.executable}")
    QGuiApplication.setHighDpiScaleFactorRoundingPolicy(
        Qt.HighDpiScaleFactorRoundingPolicy.PassThrough
    )
    launch_log("QGuiApplication()")
    app = QGuiApplication(sys.argv)
    app.aboutToQuit.connect(lambda: launch_log("QGuiApplication.aboutToQuit"))

    launch_log("Backend()")
    backend = Backend()

    def _open_release_url(url: str) -> None:
        if url:
            QDesktopServices.openUrl(QUrl(url))

    backend.openReleaseUrl.connect(_open_release_url, Qt.ConnectionType.QueuedConnection)

    engine = QQmlApplicationEngine()
    engine.setOutputWarningsToStandardError(True)
    engine.rootContext().setContextProperty("backend", backend)
    qml_url = QUrl.fromLocalFile(str(APP_ROOT / "main.qml"))
    launch_log(f"engine.load({qml_url.toString()})")
    engine.load(qml_url)

    roots = engine.rootObjects()
    if not roots:
        launch_log("ERROR: engine.rootObjects() пусто — QML не загрузился или ошибка разбора")
        return 1

    launch_log(f"rootObjects count={len(roots)}")
    for i, obj in enumerate(roots):
        cname = obj.metaObject().className()
        extra = ""
        if isinstance(obj, QQuickWindow):
            g = obj.geometry()
            extra = (
                f" visible={obj.isVisible()} modality={obj.modality()} "
                f"geometry=({g.x()},{g.y()} {g.width()}x{g.height()})"
            )
        launch_log(f"  root[{i}] {cname}{extra}")

    if os.environ.get("REZKA_SHOW_CURSOR") != "1":
        blank = QCursor(Qt.CursorShape.BlankCursor)
        for obj in roots:
            if isinstance(obj, QQuickWindow):
                obj.setCursor(blank)

    if sys.platform == "linux" and os.environ.get("REZKA_CEC", "1") == "1":
        for qt_key, slot in (
            (Qt.Key_VolumeUp, backend.cecVolumeUp),
            (Qt.Key_VolumeDown, backend.cecVolumeDown),
            (Qt.Key_VolumeMute, backend.cecVolumeMute),
        ):
            sc = QShortcut(QKeySequence(qt_key), app)
            sc.setContext(Qt.ShortcutContext.ApplicationShortcut)
            sc.activated.connect(slot)

    launch_log("entering app.exec()")
    return app.exec()


if __name__ == "__main__":
    launch_log(f"===== start pid={os.getpid()} argv={sys.argv!r}")
    exit_code = 1
    try:
        exit_code = main()
    except SystemExit as e:
        launch_log(f"SystemExit {e.code!r}")
        raise
    except BaseException:
        launch_log("UNCAUGHT:\n" + traceback.format_exc())
        raise
    else:
        launch_log(f"main() finished with code {exit_code}")
        sys.exit(exit_code)
