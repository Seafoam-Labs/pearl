# Pearl translations and language packages

Status: package architecture and initial migration implemented, October 23, 2026.
Broader coverage and language acceptance remain open as recorded below. Separate
language packages are a required part of the implementation.

Pearl will support additional interface languages through independently
installable translation packages. English source messages remain available in
the base application as a fallback. German and every other translated language
ship in language packs, without embedding their catalogs in application binaries
or requiring all translations to be installed with Pearl.

The first delivery establishes the package contract and shared Zig translation
API and moves existing German translations into the first pack. The
[translation and packaging guide](../translations/README.md) documents the
implemented interfaces, build commands, and contributor workflow.

## Implementation record

| Stage | Implemented | Remaining acceptance |
| --- | --- | --- |
| L1 | Eight catalog domains, versioned manifests, per-language file ownership, locale resolution without generated libc locale data, and a documented metadata consumer boundary | External desktop/software-store metadata remains English; Pearl's own launcher uses contextual catalog lookup |
| L2 | Shared Zig MO reader, contextual/plural lookup, bounded named/numbered formatting, AST extraction with comments/references, schema generation, validation, independent builds and source archives | Continue extending regression cases as real translation contributions arrive |
| L3 | Former inline German pairs and gallery catalog moved into `translations/de`; migrated German boolean branches removed; English source fallback retained | German is a partial seed and needs native-speaker review; it is not advertised as complete |
| L4 | Installed-language selector with Apply/Discard, missing-pack retention, verified Settings language inheritance, known Aqueous field/option mappings, translated calendar labels and regional week ordering | Remaining constructed status/error text, date/number display patterns, custom layout direction and narrow/large-text workflows need the full coverage audit |
| L5 | Shared lookup integrated into login/lock, chooser/capture, portal, assistant, CLI help and Phyto/Dome/Coral; explicit greeter configuration and helper startup policy | Full workflow acceptance for each executable, especially real authentication and provider-owned text, remains separate from compilation |
| L6 | Arch and Devario catalog-only recipes, contributor/licensing documentation, source export, successful Shelly package build, staged update/removal and malformed-pack tests | Native-language, screen-reader, hardware/layout, font and distribution-release signoff remains pending |

The runtime is in `src/i18n/`; extraction and package validation are Zig tools.
`translations/build.zig` builds data packages without GTK or application binaries.
The current generated templates inventory over 2,100 messages, including the
pinned Aqueous schema. Coverage percentages describe those catalog keys, not an
assertion that every application string has already been inventoried.

Verification completed for the initial delivery:

- Root model tests and application builds, optional greeter build/unit tests,
  and bundled application builds and unit tests.
- Translation unit and staged-runtime tests: ordered locale fallback, overrides,
  system/user separation, UTF-8, contexts, plural rules, placeholders, both MO
  byte orders, corrupt bounds, compatibility, updates and removal.
- A catalog-only source export built and tested independently. Shelly produced
  `pearl-lang-de-1.1-1-any.pkg.tar.zst`; its payload contains catalogs, a manifest,
  credits and licensing data, with no application executables. No package was
  installed into the development host.
- Private headless GTK startup and captures for English, installed German,
  missing packs, synthetic RTL and CJK packs. Arabic shaping and mirrored gallery
  layout were visible. The Japanese fixture showed missing-glyph boxes because
  this host lacks CJK fonts. This is a recorded font acceptance gap, not a passed
  CJK language certification.

The original scope and acceptance requirements below remain the checklist for
subsequent coverage work; passing the initial build and smoke tests does not mark
all L4–L6 acceptance criteria complete.

## Scope

Cover the shell, launcher, bar, calendar, service panels, notifications generated
by Pearl, Settings, greeter, lock screen, file chooser, capture picker, portal
dialogs, and assistant interface. Include tooltips, accessible names, status and
error messages, keyboard shortcut descriptions, desktop entries, and application
metadata. Human-readable command-line help and errors belong in the inventory;
JSON output, protocol values, error codes, and diagnostic identifiers stay stable.

Phyto, Dome, and Coral need their own catalog domains and coverage. Their
translations may share a language package while the applications are distributed
as part of Pearl. Independently distributed applications may provide separate
language packages using the same conventions.

Translation does not alter user text, file names, device identities, application
IDs, configuration keys, or command syntax. Application-provided notification
content, plugin content, authentication-provider messages, and assistant-generated
answers are separate sources of text. Translate Pearl's surrounding interface;
do not reinterpret those sources as Pearl message keys.

Automatic translation services, changing the system locale or keyboard layout,
installing packages from Settings, and live language switching are outside the
first delivery. Additional calendar systems are separate work; the current
Gregorian calendar still needs localized labels and regional week ordering.

## Baseline at investigation

| Area | Baseline behavior | Required change |
| --- | --- | --- |
| [Gallery catalogs](../src/ui/i18n.zig) | Compiled English and German structs; language enum limited to `en` and `de` | Use the shared catalog API and separately installed packs |
| [Desktop translation helper](../src/desktop/text.zig) | Inline English/German pairs; examines only the first GLib language preference | Replace with catalog lookup and consistent fallback handling |
| [Settings window](../src/settings/window.zig) and [power page](../src/settings/power_view.zig) | Read `LANG` and retain a `german` boolean | Use the same resolved language as other Pearl interfaces |
| [Surface formatting](../src/ui/surfaces/manager.zig) | Chooses between compile-time English/German format strings | Add translated message formatting with checked placeholders |
| [Calendar](../src/desktop/calendar.zig) | English month and weekday arrays; Monday-first grid | Localize names and implement regional week ordering |
| [Clock formatting](../src/desktop/clock_time.zig) | GLib date formatting with fixed display patterns | Separate regional formatting from UI language and preserve explicit clock preferences |
| [Settings presentation protocol](../src/settings/live_protocol.zig) | Carries display strings from the backend | Define which side translates each message |
| [Aqueous settings](../src/desktop/aqueous_settings.zig) | Displays schema labels and descriptions received from Aqueous | Map known stable field IDs to catalog messages and retain upstream fallback text |
| [Greeter](../src/greeter/screen.zig), [lock screen](../src/lock/screen.zig), and auxiliary interfaces | Many English literals with no shared translation API | Inventory and migrate owned interface messages |
| [Preferences](../src/config/preferences.zig) | No shell interface-language preference | Add a validated optional override with backward-compatible defaults |

The former catalog unit test checked German key coverage and UTF-8, plus a
German locale and English fallback. It passed during the initial investigation
and has been superseded by shared runtime, extraction and package tests.
Existing component and desktop integration tests exercise some German views;
they do not establish complete translation coverage.

## Required language package contract

### Package contents and ownership

- Use one independently installable package per language or regional variant.
  The initial package is `pearl-lang-de`; additional packages follow the same
  locale suffix convention, such as `pearl-lang-fr`. Distribution-specific
  spelling and locale-to-package mapping must be documented before release.
- Packages contain compiled catalogs, pack metadata, translation credits and
  licenses, and any supported translated application metadata. They contain no
  application executables or executable translation plugins.
- English source fallback is sufficient to start and use Pearl with no language
  packs installed. Remove built-in German catalogs and inline German alternatives
  as their callers migrate. The gallery must follow the same production model;
  test-only catalogs remain isolated fixtures.
- A language pack can contain several catalog domains, including a greeter
  domain. Installing greeter translations must not require installing the full
  desktop shell or unrelated bundled applications.
- Each file has one package owner. Stable and development variants must either
  share a compatible catalog contract or use distinct domains and installation
  paths. They must not silently overwrite each other's translations.
- Application packages must not depend on every language pack. Distributions may
  offer an optional aggregate package, but individual packs remain usable alone.

Use standard gettext catalog paths under the configured installation prefix,
such as `share/locale/de/LC_MESSAGES/pearl.mo`. Define additional domains for
components that have independent installation or release lifecycles. Keep pack
manifests under `share/pearl/language-packs/`. The implemented domain names and
boundaries are listed in the [package contract](../translations/README.md#package-contract-1).

Each manifest records its format version, canonical locale, native language name,
text direction, catalog domains, translation revision, supported catalog contract
versions, and per-domain coverage. Validate metadata and bound its size. Derive
catalog paths from validated identifiers within the installation prefix, rather
than accepting arbitrary paths from manifests.

Desktop-entry and AppStream localization need an explicit packaging design:
putting a `.mo` file on disk does not automatically localize arbitrary metadata.
Choose and test a supported lookup or package-managed generation mechanism.
Language packs must not each ship competing copies of the base `.desktop` file
or modify another package's owned files through an ad hoc installation script.
Document the selected mechanism and its consumers before declaring metadata
translation complete.

### Compatibility and package lifecycle

Define a catalog contract version per domain, separate from the translation
revision. Adding messages within a compatible contract permits older packs:
missing messages fall back to English and unused entries are ignored. Change
message identity or context when meaning or placeholder requirements change.
Incompatible contract versions are rejected for that domain with a usable
fallback; they must not prevent startup.

Translation-only releases must be possible without rebuilding Pearl binaries or
changing their package revision. Package dependencies should express the actual
catalog compatibility contract, not force an exact application patch version
when catalogs remain compatible.

Installation, updates, and removal belong to the distribution package manager.
Support the repository's maintained packaging targets. This development host uses
Shelly: inspect its available commands before installing dependencies or building
packages. Arch recipes are packaging targets and do not identify the host OS.

Resolve catalogs for each process at startup. Do not hot-reload an active process
or promise immediate changes after a package transaction. Verify that updates
and removal leave running applications usable and that the next launch resolves
the new installed state. Never restart the locker, greeter authentication flow,
or shell automatically to apply a language change.

## Translation architecture

### Catalogs and Zig API

Use gettext `.po` files for translator-maintained source catalogs and `.mo` files
for installed runtime catalogs. Provide one shared Zig module for domain setup,
message lookup, context, plural selection, and formatted messages. English source
messages and context identify entries; missing translations return English.

The pinned GLib bindings already expose gettext lookup functions. Keep runtime
integration and build tooling in Zig, using the existing bindings or minimal
direct C ABI declarations where necessary. No C implementation layer is required
solely to call gettext. Initialize locale and catalog domains before constructing
UI or starting workers that depend on locale.

The installed GNU `xgettext` 1.0 does not list Zig as a supported input language.
Provide a Zig extraction utility using token or syntax-aware parsing of a small,
documented translation-call convention, or an explicit checked message manifest.
Do not rely on regex extraction or treating arbitrary Zig as C. Extraction must
preserve contexts, plural forms, translator comments, and source references, and
handle Zig string escaping and multiline literals.

Create catalog-only build, validation, and staging targets that do not compile
the shell, initialize GTK, or require optional application dependencies. A
translation source release should include templates and everything needed to
build the language packages. Building the base application must not implicitly
install all catalogs. Keep development staging explicit so local testing exercises
the same lookup contract as packaged installations.

### Variables and plurals

Zig's `std.fmt` requires compile-time format strings. Runtime translations cannot
be passed directly to it. Implement a bounded Zig formatter with a small named
placeholder syntax, for example `Copied {count} files to {destination}`. Use
gettext plural selection before substituting values. Translators must be able to
reorder placeholders and translate complete sentences.

Validate placeholder names and types against the source message, including every
plural form. Specify literal-brace escaping, output size limits, ownership, and
NUL termination for GTK calls. Reject malformed translations at package build
time and fall back safely if incompatible content reaches runtime. Use text APIs
by default and escape inserted values where markup is explicitly required.
Never treat catalog text as a `printf` format string with unchecked arguments.

Replace concatenated sentence fragments with complete messages. Include context
for ambiguous words such as “Open” and “Default”, and translator comments for
short labels, units, and accessibility-only text. Do not assume every language
has only singular and plural forms.

## Language selection and process behavior

Default to **Follow system**. Use all requested language preferences and
their regional fallbacks, with documented handling of `LANGUAGE`, `LC_ALL`,
`LC_MESSAGES`, `LANG`, and the `C` locale. Replace all direct `LANG` checks,
`german` flags, and first-element-only decisions with the shared policy.

Add an optional saved language override, validated against a canonical locale
syntax. Missing preferences preserve system behavior. A saved language whose
pack has been removed remains a recoverable preference: show the fallback state
without rejecting the rest of the preferences or silently rewriting the choice.
Follow the existing draft, Apply, Discard, and conflict-handling conventions.

Settings lists **Follow system**, **English**, and installed compatible packs
using native language names. Show incomplete coverage honestly. Do not imply
that an uninstalled pack is available for immediate use; a future package browser
must distinguish available packages from installed languages. Explain that a
saved change takes full effect on the next session start.

For the first delivery, capture one effective UI language for a running Pearl
session. Propagate it through the verified launch/protocol paths to Settings,
the locker, and other Pearl helpers, even if the saved preference changes during
the session. Define behavior for directly launched utilities and Settings without
a connected shell. Independently launched bundled apps resolve their language
at startup. No live widget retranslation is required.

The greeter starts before a user session and needs its own system-controlled
language setting or system-locale fallback. It must not read an arbitrary user's
preferences or untrusted catalog directories before authentication. Its setting
does not implicitly change the locale of the session being launched.

Keep interface language separate from regional date and number formatting and
keyboard layout. Do not export a Pearl-only override globally to unrelated apps
or change locale while workers are running. Prototype how the selected gettext
backend and GTK stock strings behave when a pack exists but the corresponding
libc locale is unavailable. L1 must decide whether locale data is a package
prerequisite or which supported fallback applies; installing a catalog alone
must not be presented as sufficient without this verification.

## Translation boundaries

### Settings and shell messages

Prefer semantic state, stable message identifiers, and typed arguments across
Settings IPC, with translation in the displaying frontend. Identify remaining
backend-owned messages and ensure they use the session's effective language.
Version protocol changes and retain existing control IDs and action parameters.
Do not translate arbitrary server text by attempting to match English prose.

### Aqueous and external sources

Map known Aqueous schema field IDs to translated labels, descriptions, and
display names for enum values. Keep the underlying values unchanged. Unknown
fields retain their upstream text, allowing new schemas to remain usable.
Maintain coverage checks against the pinned schema inventory. Core translation
support does not require a compositor update; a future upstream localization
contract can replace the local mapping when available.

GIO application names should continue to use desktop-entry localization. Keep
user content and external service messages intact. Translate Pearl's explanation
around an external failure where necessary. Authentication prompts from PAM or
greetd remain authoritative, including their echo/secret handling.

Plugins need an explicit future locale/catalog contract to translate their own
content. Localize Pearl-owned plugin controls now and report plugin-authored
content as a separate coverage boundary. A theme or plugin name supplied by its
author is not automatically a Pearl translation key.

## Regional formatting and layout

Localize calendar month and weekday labels and apply the regional first day of
the week consistently to headers, day placement, and keyboard navigation.
Preserve explicit time-zone and 12/24-hour preferences. Audit date order, durations,
counts, percentages, file sizes, and displayed decimal values. Keep serialization,
calculator syntax, diagnostic output formats, and protocol numbers independent
of display formatting. Select and document a source for regional week rules;
message language alone is not a sufficient region identifier.

GTK and Pango provide the foundation for Unicode rendering and bidirectional
text. Audit Pearl's custom grids, physical coordinates, directional icons,
alignment, and arrow-key behavior for right-to-left interfaces. Mirror logical
navigation where appropriate while retaining physical meanings such as monitor
coordinates and audio balance. Preserve mixed-direction file paths and other
external identifiers without modifying their underlying text.

Test font fallback for CJK, Arabic, and Hebrew, including the greeter account's
environment. Document any required font or locale-data packages. Test narrow
windows, vertical bars, larger text, fractional scale, wrapping, and ellipsization
with translated text. Review accessible labels and keyboard mnemonics alongside
visible labels. Audit remaining ASCII-only search and sorting where translated
names are searchable.

## Implementation stages

| Stage | Deliverables | Exit criteria |
| --- | --- | --- |
| L1 Package and locale contract | Message inventory; package names, paths, domains, manifest and compatibility rules; locale/backend prototype; desktop metadata strategy | Demonstrate a separately staged sample pack, English fallback, contextual/plural lookup, and documented behavior when libc locale data is missing |
| L2 Shared Zig infrastructure | Runtime API, placeholder formatter, extraction, catalog validation, catalog-only staging and package build paths | Tests cover selection, context, plurals, formatting, malformed metadata, and missing/incompatible catalogs; translation builds do not rebuild apps |
| L3 German migration | Move gallery and existing inline German text into `pearl-lang-de`; remove migrated boolean language branches | Base binaries contain no migrated German catalogs; packaged German views retain existing behavior; English works with no packs |
| L4 Shell and Settings coverage | Migrate remaining owned strings, Settings IPC presentation, Aqueous mappings, calendar and regional formatting | Inventory identifies remaining gaps; locale matrix passes across primary shell and Settings workflows |
| L5 Login and auxiliary coverage | Greeter, locker, chooser, capture, portal, assistant UI, human CLI text, and bundled app domains | Each executable resolves packs correctly in its actual launch environment; authentication behavior and machine interfaces remain unchanged |
| L6 Distribution and language acceptance | Maintained package recipes, contributor guide, install/update/removal tests, metadata localization, additional-script review | Individual language packs release independently; package lifecycle and visual/accessibility acceptance pass |

English and German establish the first migration baseline. Add a language with
more than two plural forms, a CJK language, and a right-to-left language to the
validation matrix as translations and reviewers become available. Synthetic
catalogs can exercise infrastructure earlier, but do not qualify a language as
human-reviewed or complete.

## Validation and release gates

- **Catalog integrity:** deterministic extraction; correct UTF-8 and escaping;
  no duplicate conflicting context/message pairs; compatible placeholders in
  every plural form; explicit handling of fuzzy and untranslated entries;
  translation credits and licenses; per-domain coverage reports.
- **Selection:** system preference precedence; regional and ordered-language
  fallback; explicit override; English without a pack; `C` and `C.UTF-8`;
  unavailable libc locale data; saved preference after pack removal; consistent
  Settings, shell, and helper language.
- **Package lifecycle:** install one pack without unrelated packs or apps;
  translation-only update without executable changes; no conflicting file
  ownership; compatible older packs; incompatible domains; missing and malformed
  catalogs; removal while apps run; correct fallback on the next launch.
- **Presentation:** plural counts including 0, 1, 2, and language-specific cases;
  reordered placeholders; long expanded test strings; markup-sensitive values;
  narrow and scaled surfaces; fonts and mixed-direction text; translated search;
  regional week ordering and year/month boundaries.
- **Accessibility and authentication:** translated tooltips and accessible names;
  keyboard navigation and mnemonics; Orca review; greeter and lock-screen prompts,
  errors, retries, and cancellation with installed, missing, and incomplete packs;
  no package-triggered authentication interruption.
- **Automation:** pin baseline integration tests to an explicit locale and run
  dedicated locale-matrix cases separately. Extend private-session harnesses to
  pass the required locale variables explicitly. Prefer stable control IDs for
  interactions and assert translated text only in localization-specific checks.

Use Zig for runtime code, extraction, validation utilities, and unit tests where
appropriate. Python may extend existing test harnesses under the repository's
testing exception. Run package and integration tests in isolated environments;
no validation step should alter the user's active desktop language or lock state.

A language is advertised as complete only when its declared component coverage
has been reviewed, packaged, and tested. Incomplete packs remain usable with
English fallback and an accurate coverage indication. Record automated results
separately from native-speaker, visual, and accessibility signoff.

## Contributor documentation and references

Add a translation guide covering message context, placeholders, plural rules,
credits, updating catalogs, previewing an installed test pack, and submitting
translation-only changes. Add a packager guide covering manifests, compatibility,
locale/font dependencies, standalone greeter installations, and independent
language package releases. Update the gallery documentation when its embedded
catalog model is replaced.

- [Current component translation behavior](COMPONENTS.md#translation-accessibility-and-motion)
- [Preferences and persistence](PREFERENCES.md)
- [Settings frontend API](SETTINGS_FRONTEND_API.md)
- [Greeter deployment](GREETER.md)
- [Testing conventions](TESTING.md)
- [GLib internationalization](https://docs.gtk.org/glib/i18n.html)
- [GLib language preference list](https://docs.gtk.org/glib/func.get_language_names.html)
- [GTK locale direction](https://docs.gtk.org/gtk4/func.get_locale_direction.html)
- [Pango text rendering](https://docs.gtk.org/Pango/)
