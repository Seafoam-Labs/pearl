# Pearl greeter login mockup

Open [index.html](index.html) directly in a browser. The preview requires no server, network access or running Pearl session.

The [implementation plan](../../GREETER_LOGIN_FORM_IMPLEMENTATION_PLAN.md) defines the native form, queued password lifecycle, PAM policy and acceptance checks.

- Open **User** and select a sample account with a mouse or the arrow keys and Enter. Escape dismisses the menu. Selection clears the password.
- Choose **Other user…** to enter Username and Password together.
- Enter sample text in Password and select **Sign in** or press Enter to simulate submission. The preview clears the input immediately and never authenticates an account.
- Use **Preview** to inspect an incorrect password, fingerprint instructions, additional authentication or an empty account list.
- Use **Theme**, **Larger text** and **High contrast** to review presentation. **Move login card** simulates moving the card across one screen. The native action moves between outputs.

The review controls above the login screen are outside the proposed greeter. Sample sessions, account discovery, refresh and authentication are simulated. Input stays only in the browser widget until it is cleared; there are no network requests, storage writes or analytics. Use sample input only.

The default preview represents validated password-first operation. The native plan also describes a policy fallback with the same visible response field enabled when PAM requests input. The prototype requires nonempty input for its simulated submission; it does not model empty-password or real PAM conversations.

Captures: [initial form](desktop.png), [open dropdown](user-menu.png), [manual user](other-user.png), [incorrect password](error.png), [light theme](light.png), [narrow screen](narrow.png).

Browser verification and its scope are recorded in [verification.json](verification.json). These captures are a design preview, not screenshots of the native GTK change.
