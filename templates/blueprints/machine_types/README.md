# machine_types/

Per-machine-type configuration. Create a subdirectory for each machine type
you want to differentiate (e.g. `dev/`, `server/`, `work/`). The name is
arbitrary — whatever you pass as `--machine-type <name>` at apply time.

Each type directory supports the same four layers as `common/`, all optional:

```
machine_types/<type>/
├── machinekit.toml   # merged on top of common/machinekit.toml (type values win)
├── Brewfile          # applied after common/Brewfile (additive)
├── home/             # applied on top of common/home/ (per-file override)
└── hooks/
    └── post-apply/   # run after common/hooks/post-apply/
```

`machinekit.toml` overrides are deep-merged — you only need to declare the
keys you want to change. To override a module config value for this type:

```toml
[module.git]
user_email = "work@example.com"
```
