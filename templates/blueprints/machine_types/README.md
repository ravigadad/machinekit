# machine_types/

Reserved for per-machine-type configuration. Pass `--machine-type <name>` (or
`MACHINEKIT_MACHINE_TYPE=<name>`) when running `machinekit apply` to identify
which machine type is being configured.

Per-type layering (dotfiles, Brewfile, hooks, machinekit.toml overrides) is
not yet implemented. See the machinekit roadmap for the planned design.
