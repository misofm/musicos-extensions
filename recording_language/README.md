# `recording_language`

`recording_language` stores one ordered `vector<LanguageCode>` on a musicos
`Recording`. The existing APIs and storage remain unchanged: at most ten valid
ISO 639-1 codes may be attached, order is caller-defined, and duplicates are
rejected. An attached empty vector means an explicit instrumental claim;
absence means that no language claim has been made.

## Mutation events

`set_languages` emits one
`RecordingLanguagesSetEvent<RecordingShare, CompositionShare>` after the
dynamic-field write, including equal replacements. Its fields are declared in
this exact
order:

```text
recording_id: address
composition_id: address
admin_cap_id: address
had_languages: bool
previous_languages: vector<vector<u8>>
languages: vector<vector<u8>>
language_count_before: u64
language_count_after: u64
was_instrumental: bool
is_instrumental: bool
max_languages: u64
```

`previous_languages` and `languages` contain the raw ordered two-byte language
codes, not `LanguageCode` values. On insertion, `had_languages` is false,
`previous_languages` is empty, the previous count is zero, and
`was_instrumental` is false. On replacement, the previous vector and all
transition fields describe the value that was present immediately before the
write; the current vector is read back after the write.

`unset_languages` emits one
`RecordingLanguagesClearedEvent<RecordingShare, CompositionShare>` after
removing any present value, including a present empty instrumental value. Its
fields are:

```text
recording_id: address
composition_id: address
admin_cap_id: address
removed_languages: vector<vector<u8>>
language_count_before: u64
was_instrumental: bool
```

An absent clear is silent. Both events carry the actual recording,
composition, and admin-cap addresses. `uid_mut` remains type-only and does not
authenticate a cap value.

## BCS sizes

Each raw code contributes three bytes: one vector length byte and two code
bytes. For `n_b` previous and `n_a` current languages, a Set event is
`125 + 3 * (n_b + n_a)` bytes: 125 bytes for an empty insertion and 185 bytes
at the maximum 10-to-10 replacement. For `n` removed languages, a Clear event
is `106 + 3n` bytes: 106 bytes for an empty instrumental value and 136 bytes
at the maximum.

Validation checks the count first (`ETooManyLanguages = 2`) and duplicate
codes second (`EDuplicateLanguage = 3`). The `language_code` dependency
rejects invalid ISO 639-1 codes during construction.
