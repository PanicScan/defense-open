use crate::report::{Evidence, FindingSeverity, RecommendedAction};

pub fn score_evidence(
    evidences: &[Evidence],
    is_system_critical: bool,
) -> (u8, FindingSeverity, RecommendedAction) {
    let mut score = evidences
        .iter()
        .fold(0u16, |total, evidence| {
            total.saturating_add(evidence.weight as u16)
        })
        .min(100) as u8;

    if is_system_critical && score >= 60 {
        score = score.min(79);
    }

    let severity = match score {
        0..=19 => FindingSeverity::Info,
        20..=39 => FindingSeverity::Low,
        40..=59 => FindingSeverity::Medium,
        60..=79 => FindingSeverity::High,
        _ => FindingSeverity::Critical,
    };

    let action = if is_system_critical && score >= 60 {
        RecommendedAction::ManualExpertReview
    } else {
        match score {
            0..=39 => RecommendedAction::Ignore,
            40..=59 => RecommendedAction::Review,
            60..=89 => RecommendedAction::Quarantine,
            _ => RecommendedAction::OfflineSecurityScan,
        }
    };

    (score, severity, action)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::report::EvidenceKind;

    fn evidence(weight: u8) -> Evidence {
        Evidence {
            kind: EvidenceKind::Persistence,
            code: "test".to_string(),
            title: "Test".to_string(),
            detail: "Synthetic evidence".to_string(),
            weight,
        }
    }

    #[test]
    fn weak_signal_stays_review_only() {
        let (score, severity, action) = score_evidence(&[evidence(45)], false);
        assert_eq!(score, 45);
        assert_eq!(severity, FindingSeverity::Medium);
        assert_eq!(action, RecommendedAction::Review);
    }

    #[test]
    fn strong_user_space_signal_recommends_quarantine() {
        let (score, severity, action) = score_evidence(&[evidence(35), evidence(30)], false);
        assert_eq!(score, 65);
        assert_eq!(severity, FindingSeverity::High);
        assert_eq!(action, RecommendedAction::Quarantine);
    }

    #[test]
    fn system_critical_item_never_auto_quarantines() {
        let (score, severity, action) = score_evidence(&[evidence(50), evidence(50)], true);
        assert_eq!(score, 79);
        assert_eq!(severity, FindingSeverity::High);
        assert_eq!(action, RecommendedAction::ManualExpertReview);
    }
}
