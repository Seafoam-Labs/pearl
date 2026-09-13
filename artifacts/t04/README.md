# T04 verification — September 13, 2026

- [Adapter results](adapter/results.json): 21 scripted IPC and real nested Aqueous
  scenarios, with per-case logs and private parent/nested/replacement compositor logs.
- [Lifecycle results](lifecycle/results.json): live session startup and shutdown,
  repeated demo cycles, worker cancellation, GTK resource cleanup and isolation.
- [Unit/lifecycle build output](checks/unit-lifecycle-build.txt): 31 pure tests,
  7 adapter unit tests and GTK lifecycle regression; 18/18 build steps pass.
- [Final adapter/build output](checks/final-adapter-build.txt): 21 adapter scenarios
  including the final oversized-icon request case; 11/11 build steps pass.

Both result manifests record tested executable hashes. All socket endpoints,
compositors, configuration files and buses used here were disposable private
instances. Live commands renamed/activated a private workspace, reloaded that
instance's configuration and exited that nested compositor. The replacement
instance demonstrated that an existing adapter does not discover a new endpoint.

See [the adapter contract](../../docs/AQUEOUS_ADAPTER.md) for reproduction and
[progress](../../docs/PROGRESS.md) for scope and remaining release checks.
