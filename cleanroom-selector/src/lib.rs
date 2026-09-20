// SPDX-License-Identifier: MIT

#![forbid(unsafe_code)]

/// Selects a directory ID using a normalized domain lookup key.
///
/// The domain is trimmed of surrounding ASCII whitespace, has exactly one
/// trailing DNS root dot removed, and is then ASCII-lowercased. An empty key
/// skips the lookup. If the lookup has no result, `default` is returned.
pub fn select_directory_for_domain<D, F>(domain: &str, default: Option<D>, lookup: F) -> Option<D>
where
    F: FnOnce(&str) -> Option<D>,
{
    let trimmed = domain.trim_matches(|character: char| character.is_ascii_whitespace());
    let without_root_dot = trimmed.strip_suffix('.').unwrap_or(trimmed);

    if without_root_dot.is_empty() {
        return default;
    }

    let normalized = without_root_dot.to_ascii_lowercase();
    lookup(&normalized).or(default)
}

#[cfg(test)]
mod tests {
    use super::select_directory_for_domain;
    use std::cell::Cell;

    #[test]
    fn lowercases_mixed_case_domain() {
        let selected = select_directory_for_domain("ExAmPlE.CoM", None, |key| {
            assert_eq!(key, "example.com");
            Some(1)
        });

        assert_eq!(selected, Some(1));
    }

    #[test]
    fn removes_one_trailing_root_dot() {
        let selected = select_directory_for_domain("example.com..", None, |key| {
            assert_eq!(key, "example.com.");
            Some(2)
        });

        assert_eq!(selected, Some(2));
    }

    #[test]
    fn trims_surrounding_ascii_whitespace() {
        let selected = select_directory_for_domain("\t example.com \r\n", None, |key| {
            assert_eq!(key, "example.com");
            Some(3)
        });

        assert_eq!(selected, Some(3));
    }

    #[test]
    fn mapped_result_overrides_default() {
        struct DirectoryId(u8);

        let selected = select_directory_for_domain("example.com", Some(DirectoryId(4)), |_| {
            Some(DirectoryId(5))
        });

        assert_eq!(selected.map(|id| id.0), Some(5));
    }

    #[test]
    fn unmapped_domain_falls_back_to_default() {
        let selected = select_directory_for_domain("example.com", Some(6), |_| None);

        assert_eq!(selected, Some(6));
    }

    #[test]
    fn empty_normalized_domain_falls_back_without_lookup() {
        let called = Cell::new(false);
        let selected = select_directory_for_domain(" \t.\r\n", Some(7), |_| {
            called.set(true);
            Some(8)
        });

        assert_eq!(selected, Some(7));
        assert!(!called.get());
    }

    #[test]
    fn missing_mapping_and_default_returns_none() {
        let selected = select_directory_for_domain::<u8, _>("example.com", None, |_| None);

        assert_eq!(selected, None);
    }

    #[test]
    fn lookup_is_called_exactly_once_for_nonempty_domain() {
        let calls = Cell::new(0);
        let selected = select_directory_for_domain("example.com", Some(9), |key| {
            calls.set(calls.get() + 1);
            assert_eq!(key, "example.com");
            None
        });

        assert_eq!(selected, Some(9));
        assert_eq!(calls.get(), 1);
    }
}
