use goblin::Object;

use crate::report::{Evidence, EvidenceKind};

pub fn analyze_executable_bytes(bytes: &[u8]) -> Vec<Evidence> {
    let Ok(object) = Object::parse(bytes) else {
        return Vec::new();
    };

    let mut evidences = Vec::new();

    match object {
        Object::PE(pe) => {
            let imports = pe
                .imports
                .iter()
                .map(|import| import.name.to_ascii_lowercase())
                .collect::<Vec<_>>();

            if has_all(
                &imports,
                &["virtualalloc", "writeprocessmemory", "createremotethread"],
            ) {
                evidences.push(Evidence {
                    kind: EvidenceKind::File,
                    code: "pe.injection_imports".to_string(),
                    title: "PE imports process injection APIs".to_string(),
                    detail:
                        "Imports include VirtualAlloc, WriteProcessMemory, and CreateRemoteThread"
                            .to_string(),
                    weight: 20,
                });
            }
        }
        Object::Mach(_) | Object::Elf(_) => return generic_executable_evidence(bytes),
        _ => return Vec::new(),
    }

    evidences.extend(generic_executable_evidence(bytes));
    evidences
}

fn generic_executable_evidence(bytes: &[u8]) -> Vec<Evidence> {
    let mut evidences = Vec::new();

    if bytes_entropy(bytes) >= 7.2 {
        evidences.push(Evidence {
            kind: EvidenceKind::File,
            code: "executable.high_entropy".to_string(),
            title: "High entropy executable".to_string(),
            detail: "File entropy suggests packing, encryption, or compression".to_string(),
            weight: 20,
        });
    }

    if contains_ascii(bytes, b"stratum+tcp")
        || contains_ascii(bytes, b"xmrig")
        || contains_ascii(bytes, b"monero")
    {
        evidences.push(Evidence {
            kind: EvidenceKind::Miner,
            code: "executable.miner_string".to_string(),
            title: "Executable contains miner-related strings".to_string(),
            detail: "Binary contains mining pool or miner family strings".to_string(),
            weight: 35,
        });
    }

    if contains_ascii(bytes, b"DYLD_INSERT_LIBRARIES")
        || contains_ascii(bytes, b"LD_PRELOAD")
        || contains_ascii(bytes, b"ptrace")
    {
        evidences.push(Evidence {
            kind: EvidenceKind::File,
            code: "executable.preload_or_ptrace_string".to_string(),
            title: "Executable contains preload or ptrace-related strings".to_string(),
            detail:
                "Binary contains strings associated with dylib/so preloading or process tracing"
                    .to_string(),
            weight: 15,
        });
    }

    evidences
}

fn has_all(imports: &[String], required: &[&str]) -> bool {
    required
        .iter()
        .all(|needle| imports.iter().any(|import| import.contains(needle)))
}

fn contains_ascii(bytes: &[u8], needle: &[u8]) -> bool {
    bytes
        .windows(needle.len())
        .any(|window| window.eq_ignore_ascii_case(needle))
}

fn bytes_entropy(bytes: &[u8]) -> f64 {
    if bytes.is_empty() {
        return 0.0;
    }
    let mut counts = [0usize; 256];
    for byte in bytes {
        counts[*byte as usize] += 1;
    }
    counts
        .iter()
        .copied()
        .filter(|count| *count > 0)
        .map(|count| {
            let probability = count as f64 / bytes.len() as f64;
            -probability * probability.log2()
        })
        .sum()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_bytes_have_zero_entropy() {
        assert_eq!(bytes_entropy(b""), 0.0);
    }

    #[test]
    fn ignores_miner_string_without_valid_executable() {
        let evidences = analyze_executable_bytes(b"not an executable with xmrig string");
        assert!(evidences.is_empty());
    }
}
