[简体中文](CONTRIBUTING.md) | English

# Contributing

Bug reports, suggestions and code are all welcome.

## Reporting

| What | Where |
|---|---|
| The app fails, crashes or misbehaves | [Issue](https://github.com/NishinoAkii/simple_live_N/issues/new/choose), "Bug report" |
| A new feature or an improvement | [Issue](https://github.com/NishinoAkii/simple_live_N/issues/new/choose), "Feature request" |
| How-to questions and settings | [Discussions](https://github.com/NishinoAkii/simple_live_N/discussions) |
| Live source scripts, new sources, translations | [simple_live_N-sources](https://github.com/NishinoAkii/simple_live_N-sources/issues) |

For a bug, give the version, system, platform and room, with steps to reproduce and logs: turn on Debug mode under Me → Other settings, reproduce the problem, then use Export logs. Accounts and cookies are masked in the exported logs, but please check before uploading. Never post accounts, cookies or passwords in an issue.

## Contributing code

### Setup

- Flutter 3.50.0 (as in `simple_live_app/.fvmrc`).
- `simple_live_core` is the core library (platform APIs, chat and live sources), `simple_live_app` is the app and `simple_live_tv_app` is the Android TV app.

```sh
cd simple_live_app
flutter pub get
flutter run
```

### Before you submit

1. `dart analyze` reports no new issues. Format only the files you changed (`dart format <file>`), not whole folders.
2. Run the related unit tests:

   ```sh
   cd simple_live_core && dart test test/<file>
   cd simple_live_app && flutter test test/<file>
   ```

   The list CI runs is in [`.github/workflows/build.yml`](.github/workflows/build.yml). Core tests that reach real websites carry the `live` tag and are skipped by default. New features should come with tests that stay offline.
3. New UI text uses the Simplified Chinese text as its key, with translations added to `zh-Hant.json` and `en.json` in `simple_live_app/assets/lang/`; see [`doc/translation.md`](doc/translation.md) (in Chinese).
4. Do not commit accounts, cookies, keys or local paths.

### Pull requests

1. Fork the repository and branch from `main`.
2. Keep one change per pull request, and describe the change and how you tested it in the template.
3. Merged changes ship in the next release; the maintainer updates the version and [`CHANGELOG.en.md`](CHANGELOG.en.md).

## Adding a platform

Write it as a live source script first: scripts update without an app release. See the [guide](https://github.com/NishinoAkii/simple_live_N-sources/blob/main/GUIDE.en.md). Open a pull request here only when the app itself needs to change.

## License

The project is released under GPL-3.0, and contributions are released under GPL-3.0 as well. When you use someone else's code, keep its copyright and license notices.
