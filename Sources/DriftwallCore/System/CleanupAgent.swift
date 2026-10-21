import Foundation

/// A small launchd job that puts back what Driftwall changed outside its own folders when Driftwall.app
/// is deleted. macOS doesn't tell an app it's being deleted, so this has to live outside the app: a
/// shell script and a per-user LaunchAgent, installed only while Driftwall has system changes in place.
///
/// What it undoes, once the app has been gone for `gracePeriod` seconds:
/// - the Animated Lock Screen: Apple's original Aerial is written back from Driftwall's backup (or, with
///   no usable backup, Driftwall's video is removed so macOS downloads Apple's again);
/// - the Screen Saver Video: Driftwall.saver and its video copy are removed;
/// - desktop pictures Driftwall replaced with still frames: the recorded originals are set again.
/// Then it removes itself. Any failure keeps everything for the next run.
///
/// It does nothing while the app exists anywhere (found again by bundle identifier if it was moved), or
/// while the volume the app was on isn't mounted (an unplugged external drive). An app in the Trash
/// counts as deleted.
public struct CleanupAgent: Sendable {
    public var label: String
    public var appPath: String
    public var bundleIdentifier: String
    /// Driftwall's Application Support folder (Aerial backup, lock-screen files, logs).
    public var supportDirectory: URL
    /// The per-user Aerial wallpaper store's `videos` folder.
    public var aerialVideoDirectory: URL
    /// `~/Library/Screen Savers/Driftwall.saver`.
    public var screenSaverPath: URL
    /// `~/Library/LaunchAgents/<label>.plist`.
    public var launchAgentPath: URL
    /// Command that makes macOS reload the wallpaper after the Aerial was restored.
    public var reloadCommand: String
    /// How long the app must be missing before anything is undone (a rebuild or update replaces it briefly).
    public var gracePeriod: Int
    /// How often launchd runs the check, in seconds (it also runs at login and when the app's folder changes).
    public var interval: Int

    public init(label: String = "local.driftwall.cleanup", appPath: String, bundleIdentifier: String,
                supportDirectory: URL, aerialVideoDirectory: URL, screenSaverPath: URL, launchAgentPath: URL,
                reloadCommand: String = "/usr/bin/killall WallpaperAerialsExtension WallpaperAgent",
                gracePeriod: Int = 600, interval: Int = 900) {
        self.label = label
        self.appPath = appPath
        self.bundleIdentifier = bundleIdentifier
        self.supportDirectory = supportDirectory
        self.aerialVideoDirectory = aerialVideoDirectory
        self.screenSaverPath = screenSaverPath
        self.launchAgentPath = launchAgentPath
        self.reloadCommand = reloadCommand
        self.gracePeriod = gracePeriod
        self.interval = interval
    }

    public var scriptURL: URL { supportDirectory.appendingPathComponent("Cleanup/cleanup.sh") }
    public var desktopScriptURL: URL { supportDirectory.appendingPathComponent("Cleanup/restore-desktop.js") }
    public var originalDesktopPicturesURL: URL { OriginalDesktopPictures.url(in: supportDirectory) }
    public var logURL: URL { supportDirectory.appendingPathComponent("Cleanup/cleanup.log") }

    /// Shell single-quote quoting: safe for any byte except NUL.
    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public func script() -> String {
        """
        #!/bin/bash
        # Installed by Driftwall. If Driftwall.app is deleted, this puts back what Driftwall changed outside
        # its own folders, then removes itself. Run by launchd: at login, when the app's folder changes, and
        # every \(interval / 60) minutes. It does nothing while Driftwall.app exists.
        set -u
        APP=\(Self.quote(appPath))
        BUNDLE_ID=\(Self.quote(bundleIdentifier))
        SUPPORT=\(Self.quote(supportDirectory.path))
        AERIALS=\(Self.quote(aerialVideoDirectory.path))
        SAVER=\(Self.quote(screenSaverPath.path))
        LABEL=\(Self.quote(label))
        PLIST=\(Self.quote(launchAgentPath.path))
        DESKTOP_JS=\(Self.quote(desktopScriptURL.path))
        ORIGINAL_PICTURES=\(Self.quote(originalDesktopPicturesURL.path))
        LOG=\(Self.quote(logURL.path))
        GRACE=\(gracePeriod)
        MARK="$SUPPORT/Cleanup/app-missing-since"

        log() { mkdir -p "$(dirname "$LOG")"; printf '%s %s\\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG"; }
        reload_wallpaper() { \(reloadCommand) >/dev/null 2>&1 || true; }

        app_present() {
          [ -d "$APP" ] && return 0
          # On a volume that isn't mounted (an unplugged drive), the app may well still exist.
          case "$APP" in
            /Volumes/*) volume="/Volumes/$(printf '%s' "$APP" | cut -d/ -f3)"; [ -d "$volume" ] || return 0 ;;
          esac
          # Moved somewhere else? An app in the Trash counts as deleted.
          while IFS= read -r found; do
            case "$found" in */.Trash/*|*/.Trashes/*) ;; *) [ -d "$found" ] && return 0 ;; esac
          done < <(/usr/bin/mdfind "kMDItemCFBundleIdentifier == '$BUNDLE_ID'" 2>/dev/null)
          return 1
        }

        if app_present; then rm -f "$MARK"; exit 0; fi
        now=$(date +%s)
        if [ ! -f "$MARK" ]; then
          mkdir -p "$(dirname "$MARK")"; echo "$now" > "$MARK"
          log "Driftwall.app not found; undoing its changes if it's still missing in $((GRACE / 60)) minutes"
          exit 0
        fi
        since=$(cat "$MARK" 2>/dev/null || echo "$now")
        [ $((now - since)) -ge "$GRACE" ] || exit 0

        log "Driftwall.app was removed; undoing its system changes"
        done_all=1

        # 1. Animated Lock Screen: put Apple's original Aerial back.
        manifest="$SUPPORT/Aerial/manifest.json"
        if [ -f "$manifest" ]; then
          slot=$(/usr/bin/plutil -extract slotID raw -o - "$manifest" 2>/dev/null || true)
          original=$(/usr/bin/plutil -extract originalSize raw -o - "$manifest" 2>/dev/null || true)
          if [[ "$slot" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]]; then
            backup="$SUPPORT/Aerial/Backup/$slot.mov"
            aerial="$AERIALS/$slot.mov"
            if [ -f "$backup" ] && [ "$(stat -f %z "$backup")" = "$original" ]; then
              if [ -f "$aerial" ]; then
                # Written in place, so macOS keeps its download information on the file.
                if cat "$backup" > "$aerial" && [ "$(stat -f %z "$aerial")" = "$original" ]; then
                  log "Put Apple's original Aerial $slot back"
                  reload_wallpaper
                else
                  done_all=0; log "Couldn't put Aerial $slot back; trying again later"
                fi
              fi
            elif [ -f "$aerial" ]; then
              if rm -f "$aerial"; then
                log "No usable backup; removed Aerial $slot so macOS downloads Apple's original again"
                reload_wallpaper
              else
                done_all=0
              fi
            fi
          else
            log "Ignoring an unexpected Aerial record"
          fi
          [ "$done_all" = 1 ] && rm -rf "$SUPPORT/Aerial"
        fi

        # 2. Screen Saver Video: remove the screen saver and its video copy. macOS then uses its default.
        if [ -e "$SAVER" ]; then rm -rf "$SAVER" && log "Removed Driftwall.saver" || done_all=0; fi
        rm -rf "$SUPPORT/LockScreen"

        # 3. Desktop pictures Driftwall replaced with still frames.
        if [ -f "$ORIGINAL_PICTURES" ]; then
          if /usr/bin/osascript -l JavaScript "$DESKTOP_JS" "$ORIGINAL_PICTURES" >> "$LOG" 2>&1; then
            rm -f "$ORIGINAL_PICTURES"
          else
            done_all=0; log "Couldn't restore the desktop pictures; trying again later"
          fi
        fi

        if [ "$done_all" = 1 ]; then
          log "Done; removing the cleanup task"
          rm -f "$MARK" "$PLIST" "$DESKTOP_JS" "$0"
          /bin/launchctl bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || true
        fi
        exit 0

        """
    }

    /// JavaScript for Automation, run with `osascript -l JavaScript <script> <originals.json>`. Uses the
    /// AppKit bridge directly (no Apple events, so no Automation permission prompt). Displays are matched
    /// by name; originals for displays that aren't connected are skipped.
    public static let desktopRestoreScript = """
    ObjC.import('AppKit');
    function run(argv) {
      const text = $.NSString.stringWithContentsOfFileEncodingError(argv[0], $.NSUTF8StringEncoding, null);
      if (!text || text.isNil()) { return 'No originals file'; }
      const originals = JSON.parse(text.js);
      const screens = ObjC.unwrap($.NSScreen.screens) || [];
      const results = [];
      for (const key of Object.keys(originals)) {
        const entry = originals[key];
        const screen = screens.find(s => ObjC.unwrap(s.localizedName) === entry.name);
        if (!screen) { results.push('Skipped ' + entry.name + ' (not connected)'); continue; }
        if (!$.NSFileManager.defaultManager.fileExistsAtPath(entry.path)) { results.push('Skipped ' + entry.name + ' (picture missing)'); continue; }
        const ok = $.NSWorkspace.sharedWorkspace.setDesktopImageURLForScreenOptionsError($.NSURL.fileURLWithPath(entry.path), screen, $({}), null);
        results.push((ok ? 'Restored ' : 'Failed ') + entry.name);
      }
      return results.join('\\n');
    }
    """

    public func launchAgentPlist() throws -> Data {
        let appFolder = (appPath as NSString).deletingLastPathComponent
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": ["/bin/bash", scriptURL.path],
            "RunAtLoad": true,
            "StartInterval": interval,
            "WatchPaths": [appFolder],
            "ProcessType": "Background",
            "LowPriorityIO": true,
            "AssociatedBundleIdentifiers": [bundleIdentifier],
        ]
        return try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }
}

/// The desktop pictures that were set before Driftwall first replaced them, keyed by display UUID.
/// Recorded once per display, so a later Driftwall frame never overwrites the true original.
public struct OriginalDesktopPictures: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var name: String
        public var path: String
        public init(name: String, path: String) {
            self.name = name
            self.path = path
        }
    }

    public var displays: [String: Entry]

    public init(displays: [String: Entry] = [:]) {
        self.displays = displays
    }

    public static func url(in supportDirectory: URL) -> URL {
        supportDirectory.appendingPathComponent("OriginalDesktopPictures.json")
    }

    public static func load(from url: URL) -> OriginalDesktopPictures {
        guard let data = try? Data(contentsOf: url),
              let displays = try? JSONDecoder().decode([String: Entry].self, from: data) else { return OriginalDesktopPictures() }
        return OriginalDesktopPictures(displays: displays)
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(displays).write(to: url, options: .atomic)
    }

    /// Records `picture` for the display unless an original is already known. Pictures Driftwall made
    /// itself (its still frames) are never recorded as originals.
    @discardableResult
    public mutating func recordIfNeeded(displayID: String, name: String, picture: URL?, driftwallFramesDirectory: URL) -> Bool {
        guard displays[displayID] == nil, let picture else { return false }
        let framesPath = driftwallFramesDirectory.standardizedFileURL.path
        guard !picture.standardizedFileURL.path.hasPrefix(framesPath) else { return false }
        displays[displayID] = Entry(name: name, path: picture.path)
        return true
    }
}
