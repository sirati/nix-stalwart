<!-- SPDX-License-Identifier: MIT -->

# Domain directory selector

This Rust library selects an opaque directory ID for a domain. It normalizes
the domain by trimming surrounding ASCII whitespace, removing one trailing DNS
root dot, and ASCII-lowercasing the result. It skips lookup for an empty
normalized domain and otherwise uses the mapped directory when present, falling
back to an optional default.

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
