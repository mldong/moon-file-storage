///|
/// The object key a platform stores `filename` under: `base_path` with its
/// trailing separators removed, then the name. Shared by every adapter so the
/// "where does this object live" rule has exactly one home — a platform that
/// disagrees with the facade about this string would write and read different
/// keys.
pub fn object_key(base_path : String, filename : String) -> String {
  let mut end = base_path.length()
  while end > 0 && base_path[end - 1] == '/' {
    end = end - 1
  }
  let trimmed = base_path[0:end].to_owned()
  if trimmed.is_empty() {
    filename
  } else {
    trimmed + "/" + filename
  }
}
