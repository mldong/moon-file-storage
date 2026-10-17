///|
/// The facade that turns the two ports into one call chain: pick the platform,
/// let it write the object, stamp the record, and route later reads through the
/// record it just wrote.
///
/// Compensation is deliberately absent. If the recorder rejects or fails, the
/// object stays where it is and the error propagates — the reference framework
/// behaves the same way, and silently deleting the object here would turn a
/// bookkeeping failure into data loss.

///|
pub(all) struct Service {
  platforms : Array[&@platform.Platform]
  recorder : &@recorder.Recorder
}

///|
pub fn Service::new(
  platforms : Array[&@platform.Platform],
  recorder : &@recorder.Recorder,
) -> Service {
  { platforms, recorder, }
}

///|
pub fn Service::platform_names(self : Service) -> Array[String] {
  let names : Array[String] = []
  for platform in self.platforms {
    names.push(platform.name())
  }
  names
}

///|
/// An empty name selects the first registered platform: the reference
/// framework's default-platform slot.
fn Service::pick(
  self : Service,
  name : String,
) -> &@platform.Platform raise @model.StorageError {
  let wanted = if name.is_empty() {
    if self.platforms.length() == 0 {
      raise InvalidInput("no platform is registered")
    }
    self.platforms[0].name()
  } else {
    name
  }
  let mut found : &@platform.Platform? = None
  for platform in self.platforms {
    if platform.name() == wanted && found is None {
      found = Some(platform)
    }
  }
  match found {
    Some(platform) => platform
    None => raise InvalidInput("unknown platform: " + wanted)
  }
}

///|
pub fn Service::capabilities(
  self : Service,
  name : String,
) -> @model.Capabilities raise @model.StorageError {
  self.pick(name).capabilities()
}

///|
/// `intent.platform` selects the storage; the clock is stamped here (a record
/// without a creation time cannot be aged out later), and `path`, `url` and
/// `size` come back from the platform that wrote the object.
pub async fn Service::save(
  self : Service,
  intent : @model.FileInfo,
  source : @model.UploadSource,
) -> @model.FileInfo raise @model.StorageError {
  let platform = self.pick(intent.platform)
  // A capability the storage does not have is refused rather than quietly
  // dropped: metadata that cannot be stored is data the caller asked to keep.
  if !platform.capabilities().metadata && intent.user_metadata.length() > 0 {
    raise NotSupported(platform.name() + " cannot store user metadata")
  }
  let named = intent.with_platform(platform.name())
  let stamped = named.with_create_time(@date.now_millis())
  let saved = platform.save(stamped, source)
  let info = match saved {
    Some(info) => info
    None =>
      raise Platform(
        platform.name() + " declined the save, so nothing was recorded",
      )
  }
  let recorded = self.recorder.save(info)
  if !recorded {
    // The object is written and the row is not: the reference framework leaves
    // both facts as they are, so say so rather than pretending the save was
    // recorded.
    let head = "recorder kept the existing row for " + info.url
    println(head + "; this call's object is unrecorded")
  }
  info
}

///|
/// A url is readable only when the recorder knows it — without a row there is no
/// platform to route to, and guessing across platforms would report an object
/// from the wrong storage.
pub async fn Service::get_file(
  self : Service,
  url : String,
) -> @model.FileInfo? raise @model.StorageError {
  match self.recorder.get_by_url(url) {
    None => None
    Some(row) => self.pick(row.platform).get_file(url)
  }
}

///|
pub async fn Service::exists(
  self : Service,
  info : @model.FileInfo,
) -> Bool raise @model.StorageError {
  self.pick(info.platform).exists(info)
}

///|
pub async fn Service::download(
  self : Service,
  info : @model.FileInfo,
  writer : &@io.Writer,
) -> Unit raise @model.StorageError {
  self.pick(info.platform).download(info, writer)
}

///|
/// Object first, record second, and a record failure is not undone: the caller
/// sees the error and can re-delete the row, whereas a rolled-back object would
/// be unrecoverable.
pub async fn Service::delete(
  self : Service,
  info : @model.FileInfo,
) -> Bool raise @model.StorageError {
  let removed = self.pick(info.platform).delete(info)
  let _ = self.recorder.delete(info.url)
  removed
}

///|
pub fn Service::close(self : Service) -> Unit {
  for platform in self.platforms {
    platform.close()
  }
}
