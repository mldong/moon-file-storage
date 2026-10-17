// `derive(Eq, @json.ToJson, @json.FromJson)` only provides the trait instances;
// this toolchain promotes their methods to inherent ones and warns
// `implicit_impl_as_method` (the repo gate is zero warnings). Core's own packages
// declare the promotion explicitly in a separate `extends.mbt`, and so does
// moon-hutool's `date` — same shape here. The promotion is not decoration:
// `record_rows == expected_rows` and `info.to_json()` are what the recorder and
// contract tests read.

///|
pub extend HashInfo with Eq::{equal, not_equal}

///|
pub extend HashInfo with @json.ToJson::{to_json}

///|
pub extend HashInfo with @json.FromJson::{from_json}

///|
pub extend FileInfo with Eq::{equal, not_equal}

///|
pub extend FileInfo with @json.ToJson::{to_json}

///|
pub extend FileInfo with @json.FromJson::{from_json}

///|
pub extend FilePartInfo with Eq::{equal, not_equal}

///|
pub extend FilePartInfo with @json.ToJson::{to_json}

///|
pub extend FilePartInfo with @json.FromJson::{from_json}

///|
pub extend CannedAcl with Eq::{equal, not_equal}

///|
pub extend ListedDir with Eq::{equal, not_equal}

///|
pub extend ListedFile with Eq::{equal, not_equal}

///|
pub extend CopyMode with Eq::{equal, not_equal}

///|
pub extend MoveMode with Eq::{equal, not_equal}
