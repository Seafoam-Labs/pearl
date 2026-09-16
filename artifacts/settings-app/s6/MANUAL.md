# S6 — Physical desktop and assistive-technology checks

Status: pending human execution. Automated headless and private AT-SPI results
are recorded separately in [REVIEW.md](REVIEW.md).

Use a matching Pearl backend and Settings build. Record executable SHA-256 values,
Aqueous revision, GTK version, date, reviewer, hardware and desktop launch method
with each result. The automated acceptance report records the tested binary hashes.
Do not treat a private fixture pass as physical-device or screen-reader signoff.

## Physical activation and window behavior

1. Launch the installed desktop entry from the menu and pinned dock. Open a second
   page with `pearlctl settings show --page sound`; confirm one Settings window.
2. Minimize it, then use **Open full settings** from the Network flyout. Confirm
   it restores, selects Network, receives keyboard focus and releases the flyout.
3. Maximize, restore, resize and move between real monitors at 100/125/150/200%
   scale. Confirm fixed heading/footer and reachable controls at large text sizes.
4. Make a reversible Appearance draft, navigate to Sound, unplug its monitor,
   and reopen Settings from the remaining monitor. Confirm usable placement and
   the retained draft. Discard the draft afterward.
5. Close Settings and confirm Pearl continues running. Repeat while a separate
   nested Aqueous session is open and confirm launches remain in their own session.

The pinned compositor retains a window's output assignment when a headless output
is merely disabled. Automated testing verifies explicit move recovery and draft
retention. Physical unplug/remigration must be checked independently.

## Orca / actual assistive technology

1. With Orca enabled, traverse sidebar/Sections, heading, form fields and footer.
   Confirm route names, roles, selected state and focus are announced accurately.
2. Switch pages using keyboard alone. Confirm hidden pages do not enter traversal,
   the selected page is announced, and returning restores meaningful local focus.
3. Navigate Appearance at large text, edit a field and visit Sound. Confirm the
   unsaved-draft indication, service immediacy and Apply scope are understandable.
4. Open and cancel the wallpaper chooser. Confirm focus returns to the application.
5. If safe test network/Bluetooth devices are available, open and cancel a prompt.
   Confirm its label and choices are announced without exposing secret text.

## Result record

For each group, record **passed**, **failed**, or **not run**, observations and
evidence paths. Automated checks do not fill this record or approve the release.
