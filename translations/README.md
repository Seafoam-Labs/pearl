# Translating Pearl

Additional languages are **separate packages**. The application contains English
source messages; it neither embeds nor installs translated catalogs. The initial
`pearl-lang-de` pack preserves the former inline German translations and is
incomplete. Empty, fuzzy, missing, invalid, or incompatible entries fall back to
English. Installing a pack does not change an already running process.

## Build and install

Catalog builds require Zig 0.16 and GNU gettext (`msgfmt`). They do not require
GTK, the compositor, or application builds. From the repository root:

```sh
zig build --build-file translations/build.zig -Dlanguage=de --prefix /tmp/pearl-languages
zig build --build-file translations/build.zig test check -Dlanguage=de
zig build --build-file translations/build.zig test-runtime --prefix /tmp/pearl-languages
```

`test-runtime` uses the German pack plus temporary synthetic catalogs and requires
Python for the test harness. Its prefix must be private and below `/tmp`; it
restores catalog contents after testing. It checks selection, contexts, multiple
plural forms, both MO byte orders, formatting, updates, removal, incompatible
contracts, and malformed files without a graphical display.

The repository test runner also provides `--suite test-i18n` for template/unit
checks, `--suite language-packs` for catalog/runtime checks, and
`--suite language-packs-ui` for the private graphical smoke test. The latter two
create disposable installations under `/tmp`; UI checks use the runner's verified
Aqueous fixture. Run them with `python3 scripts/test.py run --suite SUITE`.

Application builds default to looking in `/usr`. For development, use the same
explicit prefix for each application:

```sh
zig build -Di18n-prefix=/tmp/pearl-languages --prefix /tmp/pearl-app
# Run inside an appropriate Wayland session, without changing the system locale:
LANG=C.UTF-8 LANGUAGE=de /tmp/pearl-app/bin/pearl --demo
```

Phyto, Dome, and Coral accept the same `-Di18n-prefix` build option. Changing the
application's `--prefix` alone does not change its catalog lookup prefix. There
is deliberately no environment variable for loading arbitrary catalog paths.

Use Settings → Appearance → Interface language to choose Follow system, English,
or an installed pack. Coverage is shown for incomplete packs. Apply uses the
normal preferences draft; sign out and start a new session to apply the language
everywhere. A removed pack remains a recoverable saved choice with an explanatory
label. Settings does not install packages or change keyboard layouts.

## Package contract 1

One package owns each language's files, shared by stable and development builds:

```text
/usr/share/locale/de/LC_MESSAGES/pearl.mo
/usr/share/locale/de/LC_MESSAGES/pearl-greeter.mo
/usr/share/locale/de/LC_MESSAGES/pearl-lock.mo
/usr/share/locale/de/LC_MESSAGES/pearl-files.mo
/usr/share/locale/de/LC_MESSAGES/pearl-agent.mo
/usr/share/locale/de/LC_MESSAGES/phyto.mo
/usr/share/locale/de/LC_MESSAGES/dome.mo
/usr/share/locale/de/LC_MESSAGES/coral.mo
/usr/share/pearl/language-packs/de.json
/usr/share/licenses/pearl-lang-de/COPYING
/usr/share/doc/pearl-lang-de/CREDITS
```

The main `pearl` domain includes shell, Settings, portal controls, and shared
widgets. The file domain includes the chooser and capture picker. Shared widgets
can use `pearl` even inside a component with its own domain. Packages contain data
only and have no mandatory dependency on the full shell, so a greeter-only
installation can use the same pack. Catalogs are read into bounded, validated,
process-owned storage; removal and updates never invalidate live UI pointers.

The generated manifest records `version: 1`, a canonical POSIX locale such as
`de`, `pt_BR`, or `sr_RS@latin`, `native_name`, `direction` (`ltr` or `rtl`), an
independent translation `revision`, and a `domains` array. Each domain records
`name`, `contract: 1`, `translated`, and `total`. Paths are derived from validated
identifiers, not supplied by the manifest. Coverage counts current template keys
present in the compiled catalog, excluding fuzzy, untranslated, and obsolete
messages. It measures catalog coverage, not a guarantee that every UI path has
been inventoried or reviewed.

Older packs remain usable as new messages are added. Change a message's source
or context when its meaning or arguments change. A domain with an unsupported
contract is ignored. Before an incompatible domain contract is released alongside
an older application, assign distinct domain/path ownership; two packages must
never compete for the same files. Translation revisions do not require rebuilding
application binaries or an exact application patch-version dependency.

Arch and Devario recipes are in `packaging/arch-lang/PKGBUILD` and
`packaging/Devario/pearl-lang-de/PKGBUILD`. The Devario recipe downloads the
checksum-pinned Pearl release archive and builds only its catalogs. It needs no
locally generated source files; `_sourcever` selects the application source
release independently of the translation package's `pkgver`.

The Arch development recipe consumes a catalog-only source archive:

```sh
zig build --build-file translations/build.zig source --prefix /tmp/pearl-language-source
```

Copy that archive beside the Arch recipe in a private build directory. On
this development host, inspect `shelly build --help`, then use `shelly build` there.
Do not assume the host is Arch or use `pacman`/`makepkg`. The small PKGBUILD shell
boundary is required by those packaging formats; compilation and validation are
Zig build targets. The recipes do not install packages into the host. Before
publication of the Arch recipe, replace its local-development `SKIP` checksum
with the archive's SHA-256 and update `pkgver`/`pkgrel` for the translation revision. An exported
source archive supports catalog builds and tests; regenerating templates needs
the full application checkout and its pinned Aqueous schema.

## Language and region

Resolution is: saved Pearl override, otherwise `LANGUAGE` in order with regional
fallbacks, otherwise `LC_ALL`, `LC_MESSAGES`, then `LANG`. Unset locale variables
mean C. Explicit C/POSIX disables `LANGUAGE`; C.UTF-8 permits translated Pearl UI.
Encoding suffixes are removed; hyphenated environment preferences are normalized
to underscores. Missing catalog entries try the next loaded fallback language,
then English. A regional modifier tries the regional/modifier combination,
language/modifier, region, and base language before the next preference.

Pearl reads MO files in Zig, so a pack works without corresponding generated libc
locale data. **GTK stock dialogs and third-party libraries still follow their own
system locale and catalogs.** Installing a Pearl pack does not translate those
libraries or provide fonts. No process-wide locale is changed for a Pearl override.
Regional date/number formatting and explicit time-zone/12-hour settings remain
separate. The Gregorian calendar translates month/day labels and uses active
`LC_TIME` data for week ordering (glibc's first-weekday/week-origin data; Monday
fallback where unavailable). GTK direction and calendar navigation follow the pack.

The shell freezes its usable language fallback chain. Verified Settings IPC and
the shell's Settings, locker, and assistant launch paths propagate that chain.
An independently started utility resolves its own startup preferences. In
particular, the portal and compositor-launched capture picker do not participate
in Settings IPC; their startup preference snapshot can differ after a preference
change until the session restarts. Environment overrides are never exported to
unrelated applications. Settings opened without a shell uses its own preferences;
an already displayed offline window retains its startup language on reconnection.

The greeter uses only its validated administrator-owned `/etc/pearl/greeter.json`
`language` setting, or its system service environment. It ignores user preferences
and inherited `PEARL_SESSION_LANGUAGES`. It does not change the logged-in user's
locale, authentication-provider prompts, or secret/echo behavior.

## Adding and updating translations

1. Run `zig build --build-file translations/build.zig extract` in the full checkout.
   This updates `.pot` files and the Aqueous mapping, never `.po` files or UI code.
   `check-templates` verifies those generated files without rewriting them.
2. Create `<locale>/language.json` with `native_name`, `direction`, and `revision`.
   Copy each domain template to `<locale>/<domain>.po` with `msginit --no-translator`;
   set the language and its actual `Plural-Forms` expression. Maintain all eight
   domains, including empty ones. Update existing catalogs using `msgmerge`.
3. Translate complete messages, contexts, every plural form, and accessible text.
   Review fuzzy matches explicitly; `msgfmt` does not install them. Preserve
   technical identifiers and user content. Add attribution to `CREDITS` and PO
   headers, and retain `COPYING`. Do not invent a license for existing text.
4. Run catalog validation and the locale tests. Validate the actual installed pack
   in primary workflows, narrow/large-text views, and its fonts and writing system.
   Language packages for scripts absent from the distribution's default fonts
   should declare the required font package dependency in their distribution recipe.
   Obtain native-speaker and accessibility review before claiming language support
   is complete. The bundled German seed has not received that new review.

Developer examples:

```zig
const i18n = @import("i18n");
label.setText(i18n.tr("Settings"));
button.setLabel(i18n.context("file action", "Open"));
label.setText(i18n.dtr("pearl-greeter", "Sign in"));
// Translators: Count of selected files; destination is a path.
const text = i18n.nmessage(&buffer,
    "Copied {count} file to {destination}",
    "Copied {count} files to {destination}", count,
    &.{ .{ .name = "count", .value = count_text },
        .{ .name = "destination", .value = destination } });
```

The AST extractor recognizes `i18n.*`, `@import("i18n").*`, and the shared `tr`
alias. Use literal domains, contexts and source messages. For static arrays, use
`i18n.mark("Source")` at declaration and translate at the display site. Adjacent
`// Translators:` comments, source lines, escapes, and multiline strings are
preserved. Do not pass user/service text to lookup. Known Aqueous IDs map to
contextual labels, descriptions and option display names; unknown fields and
values retain upstream text and all underlying values remain unchanged.

Named placeholders may be reordered; their set must match the source. `{{` and
`}}` escape literal braces. `fmt`/`fmtAlloc` accept compile-time Zig source formats
with positional tuple arguments and expose numbered `{0}`, `{1}` placeholders
to translators; only source-owned
format specifications are executed. `dcontext`, `dntr`, `dmessage`, and `dnmessage`
select a component domain explicitly. `dfmt` and `dfmtAlloc` provide the typed
formatting equivalents for a component domain. `nmessage` applies plural selection before
safe substitution. Buffers include a terminating NUL; lookup strings live until
process exit. `fmtAlloc` returns allocator-owned memory with a 16 KiB output cap.
On incompatible translated placeholders the runtime renders the English source.
Use text widget APIs; escape values separately if a UI genuinely requires markup.

## Metadata and remaining acceptance

Pearl's launcher resolves names/descriptions for its known desktop IDs through
contextual catalogs when the metadata still matches the shipped source text.
User overrides and existing external localizations are preserved. Third-party
names continue through GIO. Base desktop and
AppStream files remain single-owner English metadata; language packs do not
replace them, create duplicate desktop IDs, or run file-mutating installation
hooks. External launchers/software stores therefore do **not** gain translated
base metadata from these packs. That cross-desktop distribution integration is
still a release follow-up, not a feature implied by the presence of an MO file.

The isolated gallery smoke test is reproducible with:

```sh
python3 tests/integration/test_language_packs.py \
  --pearl /tmp/pearl-app/bin/pearl --prefix /tmp/pearl-languages \
  --aqueous /usr/bin/aqueous --output /tmp/pearl-language-ui
```

It creates temporary RTL and CJK fixture packs, starts a private compositor/bus,
captures the UI, and removes the fixtures. It needs Aqueous, `grim`, and permission
to bind private local sockets. Startup passed for English, German, missing packs,
and both fixtures on the development host. Arabic text shaped and the gallery
mirrored; the Japanese fixture exposed missing CJK fonts (missing-glyph boxes).
A language pack supplies messages, not glyphs: CJK distribution acceptance must
include a suitable CJK font family in both user and greeter environments. This
smoke test does not certify font coverage, keyboard navigation, or screen readers.

See [the implementation plan](../docs/TRANSLATIONS_IMPLEMENTATION_PLAN.md) for
the implementation status and remaining language, regional-formatting, visual,
and accessibility acceptance work. A build passing does not establish complete
German, Arabic, Hebrew, or CJK language support.
