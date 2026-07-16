# MyAnimeList

A [Noctalia](https://github.com/noctalia-dev/noctalia) v5 plugin that lets you
search anime and manga through the AniList API and open results directly on
MyAnimeList.

## Plugin

| Field   | Value |
| ------- | ----- |
| ID      | `gabrielnathan929/myanimelist` |
| Entries | Panel: `browser`; launcher: `launcher` |

## Usage

Open the panel from the launcher by typing `/myanimelist`, or send a query
directly: `/myanimelist <search term>`. You can also bind it in your compositor:

```sh
noctalia msg panel-toggle gabrielnathan929/myanimelist:browser
```

### Search

| Action                       | Effect                                   |
| ---------------------------- | ---------------------------------------- |
| Type in the search box       | Enter your query                         |
| Press Enter or click Search  | Fetch results from AniList               |
| Anime / Manga / Both         | Filter the media type                    |
| Click a cover card           | Open the result on MyAnimeList           |
| Prev / Next                  | Navigate through result pages            |

### Launcher

| Action                          | Effect                                  |
| ------------------------------- | --------------------------------------- |
| `/myanimelist`                  | Open the panel with an empty search     |
| `/myanimelist <search term>`    | Open the panel with the query pre-filled |

## Storage

Cover images are cached locally:

| Type  | Path                                  |
| ----- | ------------------------------------- |
| Anime | `~/noctalia/covers/anime/<id>.jpg`    |
| Manga | `~/noctalia/covers/manga/<id>.jpg`    |

## Requirements

- Noctalia >= 5.0.0
- An active internet connection for the AniList API
- No external system dependencies

## License

MIT.
