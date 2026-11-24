# AO3 Downloader – HTML support (KOReader user patch)

A [KOReader user patch](https://koreader.rocks/doc/modules/userpatch.html) that adds **HTML downloads**
to the AO3 Downloader plugin, for the time AO3 does not offer EPUB downloads.

It is a single file in `koreader/patches/`. **The plugin folder is never modified**, so plugin updates
cannot erase it. Delete the file to remove it.

## Features

- **Separate HTML downloads.** HTML works have their own list, their own history file and their own
  folder. Existing EPUB downloads, the EPUB history and the EPUB folder are never written to.
- **HTML as the download format** (switchable to EPUB in the configuration). Download by ID, browse
  and search results, and Update all use HTML.
- **Update on an EPUB work never touches the EPUB.** It checks for an HTML copy of the same work:
  - no HTML copy → asks whether to download one;
  - HTML copy exists → asks whether to update it.
- **"Download as EPUB" button** in the HTML work options. It uses the plugin's normal EPUB download, so
  it starts working again by itself once AO3 serves EPUB files; the result goes to the EPUB history.
- **No chapter tracking for HTML works** (no "Open at chapter", no automatic chapter progress).
  Read status is per work, with a manual *Mark as read / unread*. Kudos, comment, bookmark and subscribe
  still work in the reader.
- **Safe downloads.** A download goes to a temporary file first and replaces the old file only after AO3
  answered with HTTP 200 and the content really is HTML, so a failed update cannot damage an existing file.

## Requirements

- KOReader with the AO3 Downloader plugin (the one providing the *Fanfic* menu: `fanfic_menu.lua`,
  `downloaded_fanfics.lua`, `fanfic_reader.lua`, `AO3_downloader_client.lua`).
- An AO3 account/cookies set up in the plugin if you download restricted works (the patch reuses the
  plugin's saved cookies).

## Install

**With a plugin manager:** in the Storefront or App Store plugin, open the *Patches* section and search
for `ao3downloader-html`. Install, then restart KOReader.

**Manually:**


1. Copy `2-ao3downloader-html.lua` into the `patches` folder of your KOReader data directory
   (create the folder if it does not exist), for example:
   - Kobo: `.adds/koreader/patches/`
   - Kindle: `koreader/patches/`
   - Android: `<koreader data dir>/patches/`
2. Restart KOReader.
3. Open the AO3 Downloader main menu. You should see two new entries:
   - **View HTML downloads**
   - **HTML configuration**

## Usage

- **HTML configuration**
  - *Download format*: HTML (default) or EPUB. In EPUB mode the plugin behaves exactly as without the patch,
    apart from the extra HTML menus.
  - *HTML folder*: default is a folder named `HTML` inside your plugin fanfic folder. Only new downloads use a
    changed folder.
- **View HTML downloads**: works grouped by fandom. Work options: Open, Update, Mark as read/unread,
  Download as EPUB, View Details, Delete.
- **Update** on a work that is only downloaded as EPUB: see the two cases above.

### Files the patch creates

| What | Where |
|---|---|
| HTML history | `<koreader data dir>/fanfic/fanfic_history_html.json` |
| HTML files | the *HTML folder* setting |
| Settings | two new keys in the plugin's `fanfic.lua` settings file: `ao3html_download_format`, `ao3html_folder` |

### If you remove the patch

The HTML files stay on the device and still open from the KOReader file browser as normal books.
The plugin just no longer lists them. The EPUB side is unaffected. The history file and the two settings
are left behind unused; put the patch back and everything reappears.

## How it works

Everything is hooked at runtime from outside the plugin:

- `PluginLoader:loadPlugins` – the patch applies itself right after the plugin has loaded.
- `fanfic_menu.show` – adds the two main-menu entries and gets the plugin class.
- Plugin class methods `DownloadFanfic` / `UpdateFanfic` – dispatch by format and add
  `DownloadFanficHTML`, `UpdateFanficHTML`, `DownloadFanficEpub`.
- `downloaded_fanfics.update` / `.checkIfStored` – keep HTML records out of the EPUB history and let
  the browse list show HTML status.
- `fanfic_reader.onPageUpdate` – skips chapter tracking for HTML works.
- `AO3_downloader_client` – gets a `downloadHtml` function.

The HTML link is built from the work ID (`<AO3 domain>/downloads/<id>/<id>.html`).

If a future plugin version renames those modules or methods, the patch does nothing and logs a warning
(search `crash.log` for `AO3Downloader HTML patch`) instead of breaking the plugin.

## Known limitations

- Other patches that hook the plugin's EPUB-only features (status filters, sync, missing-file checks)
  do not see HTML works.
- Without chapter tracking there is no per-chapter progress for HTML works.
- A leftover HTML file that is not in the HTML history is not detected as an existing copy; the work is
  looked up by AO3 ID in the history.
- AO3 rate limiting (HTTP 429) is reported as an error; the patch does not queue or retry for minutes.

## License

MIT
