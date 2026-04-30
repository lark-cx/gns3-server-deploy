# TODO.md  Convention Adoption

`[x]` done, `[-]` partial, `[ ]` not started

---

## Phase 1: Low-Hanging Fruit (done or nearly done)

- [x] `set -euo pipefail` + `IFS=$'\n\t'`
- [x] `readonly PATH` (Linux-only, homebrew paths removed)
- [x] Structured header block with metadata
- [x] `_READONLY_GLOBAL_` naming for constants
- [x] `_local_var` naming for function locals and iterators
- [x] `"${VAR}"` expansion everywhere (quoted + braced)
- [x] `log_*` hierarchy (`info`, `ok`, `warn`, `error`, `fatal`)
- [x] `log_warn_sticky`->`WARN_MESSAGES` array
- [x] `ensure_directory` / `ensure_config` / `require_file` helpers
- [x] `fetch_file` (stdout-based, composable)
- [x] `render_template` (stdin-based, `{{KEY}}` substitution)
- [x] `enable_and_start` with retry loop
- [x] Predicates: `file_exists`, `dir_exists`, `var_exists`, `port_open`
- [x] `if/then/fi` instead of `[[ ]] &&` shorthand (most converted)
- [x] `encrypted_copy` uses `openssl enc` with `-pbkdf2`
- [x] Decrypt commands match encryption params
- [x] `gns3_repo_present` handles deb822 format
- [x] Sudoers lines have no leading whitespace
- [x] Stray box-drawing chars removed from section headers
- [x] `fetch_resource` removed  `fetch_file` used everywhere
- [x] IP lookups cached as `SERVER_PUBLIC_IP` / `SERVER_PRIVATE_IP` / `SERVER_HOSTNAME`
- [x] No redundant IP re-checks mid-script
- [x] `.shellcheckrc` with justified exclusions
- [-] Remaining `[[ ]] && / ||` patterns  most converted, grep to find stragglers

---

## Phase 2: Structural Alignment

- [ ] Replace `on_error()` + separate `INT/TERM` trap with single `cleanup()` on `EXIT`
  - Convention: `trap cleanup EXIT` as first line of `main()`
  - `cleanup()` preserves exit code, disarms traps, `set +e`
  - Restart GNS3 on failure (current `on_error` behavior) moves into cleanup
  - INT/TERM: set context flag and `exit` - cleanup runs via EXIT trap
- [ ] Add `setup_tempdir()` - centralized `TEMP_DIR` used by `apt_retry` and `ensure_config`
  - Currently both use ad-hoc `mktemp`
  - `ensure_config` should use `mktemp "${TEMP_DIR}/..."` instead of `mktemp "${_path}.XXXXXX"`
- [ ] Add tracking arrays wired to helpers:
  - `DIRECTORIES_CREATED` ← `ensure_directory` appends
  - `SERVICES_ENABLED` ← `enable_and_start` appends
  - `PACKAGES_INSTALLED` ← `install_packages` populates (optional)
  - Summary reads from these arrays
- [ ] Add `ROLLBACK_SERVICES` / `ROLLBACK_DIRS` typed registries
  - `cleanup()` iterates in reverse on failure
- [ ] Replace `flock` lockfile with `mkdir`-based lock + stale PID detection (skeleton pattern)
- [ ] Remove `WARNINGS_OCCURRED` or use it - currently set but never read
- [ ] Add `require_args` to helper functions (from skeleton)

---

## Phase 3: Naming & Organization

- [ ] Standardize template placeholder names
  - Current: mixed `_DEPLOY_MARKER_` / `_listen_host` / `GNS3_PORT` / `_hw_accel`
  - Target: consistent `SCREAMING_SNAKE` for all placeholders (they're config values, not locals)
- [ ] Rename phase functions to convention verbs:
  - `preflight_checks`->`preflight`
  - `setup_config_server`->`config_server`
  - `configure_firewall`->`firewall`
  - `apply_sysctl_hardening`->`hardening`
  - `start_services`->(merge into per-service phases or remove)
  - `print_summary`->`summary`
- [ ] Rename sub-functions with phase prefix:
  - `setup_groups`->`acct_create_groups`
  - `setup_gns3_user`->`acct_create_gns3_user`
  - `propagate_groups_to_invoker`->`acct_add_invoker`
  - `add_gns3_repository`->`repo_add_gns3`
  - `add_docker_repository`->`repo_add_docker`
  - VPN functions: `ovpn_*` and `wg_*` prefixes
- [ ] Reorder function definitions to match execution order
- [ ] Add INDEX section to header mapping functions to sections
- [ ] Add `VERSION` constant, print in `--help` and summary
- [ ] Cache `_SCRIPT_DIR_` as readonly global (currently computed multiple times in `fetch_file`)

---

## Phase 4: Macro Refactor

- [ ] Two-tier `main()` structure:
  ```
  main->bootstrap->preflight->repositories->packages →
         accounts->gns3->docker->openvpn->wireguard →
         welcome->firewall->hardening->config_server →
         validate->summary
  ```
- [ ] Each phase is a noun function containing only sub-function calls
- [ ] Sub-functions use `phase_verb_noun` naming
- [ ] Phase banner comments with purpose description
- [ ] Flag gating in `main()` with `if/then`:
  ```bash
  if [[ "${WITH_DOCKER}" -eq 1 ]]; then docker; fi
  if [[ "${WITH_OPENVPN}" -eq 1 ]]; then openvpn; fi
  ```
- [ ] Add predicate functions for recurring checks:
  - `service_active` / `user_exists` / `interface_up` / `repo_present` / `packages_installed`
- [ ] Move `apply_option_flags` (rollup) into its own named phase or call from `main()` before bootstrap

---

## Phase 5: Multi-File Split (future, when script exceeds ~1000 LOC of logic)

- [ ] `conf/` - readonly vars/arrays per feature
- [ ] `lib/`  source-only helpers, no `main()`
- [ ] `mod/`  executable modules with numeric prefix ordering
- [ ] `bootstrap.sh`  top-level orchestrator, executes `mod/*.sh`
- [ ] Source guards: `[[ -n "${_LIB_X_LOADED:-}" ]] && return 0`
- [ ] Direct-execution guards on sourced files

---

## Ongoing / Per-Commit

- [ ] `shfmt -i 2 -ci` before commit
- [ ] `shellcheck` zero warnings (with `.shellcheckrc` exclusions)
- [ ] Update `Changed:` date in header on substantive edits
- [ ] Update INDEX when function structure changes
- [ ] Convention: Check / Do / Verify for every action
- [ ] Convention: secrets never as function arguments; use env/files/stdin
- [ ] Convention: `backup_file` before modifying existing configs (not yet implemented)

---

## Known Deferred Items

- [ ] `check_integrity()`  SHA256 validation for downloaded resources
- [ ] `--with-optimization` phase  TCP/KVM tuning (BBR, swappiness, etc.)
- [ ] 26.04 codename fallback  check GNS3 PPA Packages.xz for actual content
- [ ] OpenVPN client.ovpn still uses heredoc (PEM blocks don't work with `render_template`)
- [ ] `docker.list` still uses heredoc (inline `$(dpkg --print-architecture)` call)
- [ ] Validate function could check `ufw status numbered` rule count matches expectations
- [ ] Landing page: version-matched GNS3 client download URLs via JS
- [ ] GPG-signed bootstrap at `lrk.cx/gns3`

---
