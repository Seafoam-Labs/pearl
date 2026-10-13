# Project instructions

Pearl is a Zig project. These instructions apply throughout the repository.

## Language policy

- Write all implementation code in Zig, including new features, application logic, utilities, and build tooling wherever possible.
- Use Zig for tests where appropriate. Python may be used for testing, test harnesses, and validation scripts as needed; do not use Python for application implementation.
- Use any other language only when absolutely necessary because a required platform, dependency, or integration cannot reasonably be supported in Zig.
- Keep any necessary non-Zig code minimal, limit it to the required integration boundary, and document why it is necessary.
- Existing code in another language is not a reason to introduce more of it. Prefer Zig for new implementation and changes whenever feasible.
