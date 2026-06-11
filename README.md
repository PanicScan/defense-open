# Defense Open

Defense Open is the public, auditable core for Defense: a local-first endpoint
defense platform being built from first principles.

This repository is not a renamed legacy scanner, not a USB-scanner product, and
not a complete XDR implementation. The current public scope is intentionally
small:

- portable Rust core analysis primitives;
- local-only file, persistence, process, network, wireless, and Bluetooth
  evidence collection where platform capabilities allow it;
- non-executable built-in rule schema and sample rules;
- redacted report/export structures;
- CI gates for formatting, tests, portability, and no-upload behavior.

## Current Boundaries

Defense Open does not currently claim advanced enforcement, guaranteed
prevention, complete unknown-threat coverage, production distributed inference,
public collaborative training, or a replacement for built-in platform
protections.

Destructive remediation is out of scope for this public core. Findings should be
treated as local evidence for user or administrator review.

## Development

```bash
cargo fmt --check
cargo test --workspace --locked
cargo clippy --workspace --all-targets -- -D warnings
bash scripts/no_upload_static_audit.sh
bash scripts/portability_contract_audit.sh
```

## Repository Split

The private Defense repository owns product vision, threat model, safety
boundaries, commercial planning, and high-risk research. This public repository
contains only the curated portable core that can be audited independently.
