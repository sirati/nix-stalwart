<!-- SPDX-License-Identifier: MIT -->

# Domain directory selector

This Rust library selects an opaque directory ID for a domain. It normalizes
the domain in three steps: it trims surrounding ASCII whitespace, removes one
trailing DNS root dot, and lowercases ASCII letters. If the normalized domain is
empty, it skips the lookup and returns the optional default. Otherwise it
returns the mapped directory if one exists, and the optional default if not.

```rust
use domain_directory_selector::select_directory_for_domain;

let selected = select_directory_for_domain(" Example.COM. ", Some(1), |domain| {
    (domain == "example.com").then_some(2)
});

assert_eq!(selected, Some(2));
```

The directory ID type is generic and does not need to implement `Clone`.

## License

This component is licensed under `MIT`. See `../licences/MIT.txt`.
