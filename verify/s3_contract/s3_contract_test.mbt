///|
// MinIO through the same contract body the local leg runs. The env gate is a
// skip, and the skip says out loud that it proved nothing.

///|
fn live_env() -> (String, String, String, String, String)? {
  let endpoint = @env.get_env_var("S3_LIVE_ENDPOINT")
  let bucket = @env.get_env_var("S3_LIVE_BUCKET")
  let region = @env.get_env_var("S3_LIVE_REGION")
  let access_key = @env.get_env_var("S3_LIVE_AK")
  let secret_key = @env.get_env_var("S3_LIVE_SK")
  match (endpoint, bucket, region, access_key, secret_key) {
    (Some(e), Some(b), Some(r), Some(a), Some(s)) => Some((e, b, r, a, s))
    _ => None
  }
}

///|
fn report_skip() -> Unit {
  let missing : Array[String] = []
  for
    name in [
      "S3_LIVE_ENDPOINT", "S3_LIVE_BUCKET", "S3_LIVE_REGION", "S3_LIVE_AK", "S3_LIVE_SK",
    ] {
    if @env.get_env_var(name) is None {
      missing.push(name)
    }
  }
  let joined = missing.join(", ")
  println("SKIP contract/MinIO, environment not supplied")
  println("missing: " + joined)
  println("SKIP IS NOT A PASS: this platform leg was not verified by this run.")
}

///|
fn s3_reading(error : @sdk.S3Error) -> String {
  match error {
    @sdk.S3Error::Service(details) => {
      let head = "s3 " + details.status_code.to_string() + " " + details.code
      head + ": " + details.message
    }
    @sdk.S3Error::InvalidConfig(detail) => "s3 config: " + detail
    @sdk.S3Error::InvalidRequest(detail) => "s3 request: " + detail
    @sdk.S3Error::Signing(_) => "s3 signing failed"
    @sdk.S3Error::Transport(_) => "s3 transport failed"
  }
}

///|
async fn residue(
  client : @sdk.Client,
  bucket : String,
  prefix : String,
) -> Int32 {
  let listing = client.list_objects({
    bucket,
    prefix: Some(prefix),
    delimiter: None,
    continuation_token: None,
    max_keys: Some(1000),
  }) catch {
    error => fail("list " + prefix + ": " + s3_reading(error))
  }
  listing.objects.length()
}

///|
/// The direct-upload leg read for real. The contract only checks that a presigned
/// PUT url has the right shape; whether a client holding **no credentials at all**
/// can actually upload with it is a question for the endpoint, so it is asked
/// here: PUT through the signed url, let the service report the object back, then
/// flip one character of the signature and require the refusal.
async fn presigned_direct_upload(
  transport : @transport.AsyncHttpTransport,
  sdk : @sdk.Client,
  platform : @s3.S3Platform,
  bucket : String,
  prefix : String,
) -> Unit {
  let key = prefix + "/presigned-direct.txt"
  let body = @utf8.encode("direct upload through a presigned url")
  let intent = @model.FileInfo::draft(
    "minio-1", prefix, "presigned-direct.txt", "txt",
  )
  let info = intent.stamped(@model.Stamp::{
    platform: None,
    path: Some(key),
    url: None,
    size: None,
    create_time: None,
    upload_id: None,
    upload_status: None,
    user_metadata: None,
  })
  let url = platform.presigned_url(info, @model.PresignMethod::Put, 120) catch {
    error => fail("presigned_url(Put) raised " + storage_text(error))
  }
  let response = transport.send(@transport.Request::{
    http_method: Put,
    url,
    headers: [],
    body: @transport.RequestBody::Bytes(body),
  }) catch {
    error => fail("direct PUT raised " + transport_text(error))
  }
  let status = response.status
  response.body.close()
  let stat = sdk.stat_object({ bucket, key, }) catch {
    error => fail("stat after direct PUT: " + s3_reading(error))
  }
  // The object the endpoint reports is the only proof the PUT was accepted.
  assert_eq(stat.content_length, body.length().to_int64())
  assert_true(status == 200 || status == 204)

  let flipped = flip_tail(url)
  let tampered = transport.send(@transport.Request::{
    http_method: Put,
    url: flipped,
    headers: [],
    body: @transport.RequestBody::Bytes(@utf8.encode("should not land")),
  }) catch {
    error => fail("tampered PUT raised " + transport_text(error))
  }
  let tampered_status = tampered.status
  tampered.body.close()
  assert_eq(tampered_status, 403)

  let _ = sdk.delete_object({ bucket, key, }) catch {
    error => fail("cleanup: " + s3_reading(error))
  }
}

///|
/// Neither error type carries a `Show` instance, so the readings are spelled out
/// rather than printed through a `to_string` that does not exist.
fn storage_text(error : @model.StorageError) -> String {
  match error {
    @model.StorageError::InvalidInput(detail) => "InvalidInput: " + detail
    @model.StorageError::NotSupported(detail) => "NotSupported: " + detail
    @model.StorageError::NotFound(detail) => "NotFound: " + detail
    @model.StorageError::Platform(detail) => "Platform: " + detail
    @model.StorageError::Recorder(detail) => "Recorder: " + detail
  }
}

///|
fn transport_text(error : @transport.TransportError) -> String {
  match error {
    @transport.TransportError::Network(msg) => "Network: " + msg
    @transport.TransportError::Timeout => "Timeout"
    @transport.TransportError::InvalidRequest(msg) => "InvalidRequest: " + msg
    @transport.TransportError::InvalidResponse(msg) => "InvalidResponse: " + msg
  }
}

///|
fn flip_tail(url : String) -> String {
  // The signature is the last query value; changing any one character of it must
  // break the check, and the tail is the cheapest character to reach.
  let last = url[url.length() - 1]
  let swapped = if last == 'f' { 'e' } else { 'f' }
  url[0:url.length() - 1].to_owned() + swapped.to_string()
}

///|
/// Whether the ACL the port sets is really recorded by the endpoint. The contract
/// body can only ask "did it refuse"; this reads the policy document back, and
/// does it in three steps so the middle one cannot be a freebie: not public
/// before, public after `PublicRead`, not public again after `Private`.
async fn acl_effect_proof(
  platform : @s3.S3Platform,
  sdk : @sdk.Client,
  platform_name : String,
  bucket : String,
  prefix : String,
) -> Unit {
  let key = prefix + "/acl-proof.txt"
  let body = @utf8.encode("acl effect subject")
  let _ = sdk.put_object({
    bucket,
    key,
    body: @transport.RequestBody::Bytes(body),
    content_type: None,
    metadata: Map([]),
  }) catch {
    error => fail("put acl proof object: " + s3_reading(error))
  }
  let intent = @model.FileInfo::draft(
    platform_name, prefix, "acl-proof.txt", "txt",
  ).stamped(@model.Stamp::{
    platform: None,
    path: Some(key),
    url: None,
    size: None,
    create_time: None,
    upload_id: None,
    upload_status: None,
    user_metadata: None,
  })
  let before = read_acl(sdk, bucket, key)
  assert_true(!before.has_all_users_read())
  platform.set_file_acl(intent, @model.CannedAcl::PublicRead) catch {
    error => fail("set_file_acl(PublicRead) raised " + storage_text(error))
  }
  let granted = read_acl(sdk, bucket, key)
  platform.set_file_acl(intent, @model.CannedAcl::Private) catch {
    error => fail("set_file_acl(Private) raised " + storage_text(error))
  }
  let revoked = read_acl(sdk, bucket, key)
  let _ = sdk.delete_object({ bucket, key, }) catch {
    error => fail("cleanup: " + s3_reading(error))
  }
  // The middle reading is the whole point, and the last one is its negative
  // control: a client that ignored the header value would look "public" forever.
  assert_true(granted.has_all_users_read())
  assert_true(!revoked.has_all_users_read())
}

///|
async fn read_acl(
  sdk : @sdk.Client,
  bucket : String,
  key : String,
) -> @sdk.GetObjectAclResponse {
  sdk.get_object_acl({ bucket, key, }) catch {
    error => fail("get_object_acl: " + s3_reading(error))
  }
}

///|
async fn run_minio(
  endpoint : String,
  bucket : String,
  region : String,
  access_key : String,
  secret_key : String,
) -> Unit {
  let prefix = "moonfs-contract-20261016"
  let domain = endpoint + "/" + bucket + "/" + prefix
  let transport = @transport.AsyncHttpTransport::new()
  let config = @sdk.Config::new(
    endpoint,
    region,
    @sigv4.Credentials::new(access_key, secret_key),
  )
  let sdk = @sdk.Client::new(config, transport)
  let platform = @s3.S3Platform::new(@s3.S3PlatformConfig::{
    platform: "minio-1",
    bucket,
    base_path: "",
    supports_acl: false,
    domain: Some(domain),
    client: sdk,
  })
  let root = @fs.tmpdir(prefix="moonfs-contract-s3") catch {
    error => fail("tmpdir: " + error.to_string())
  }
  let _ = @fs.mkdir(root, recursive=true, allow_exist=true) catch {
    error => fail("mkdir: " + error.to_string())
  }
  let recorder = @record.FileRecorder::new(@record.FileRecorderConfig::{
    root_dir: root,
  })
  let service = @storage.Service::new([platform], recorder)
  let fixture = @contract.Fixture::{
    label: "minio",
    platform: "minio-1",
    base_path: prefix,
    domain,
    service,
    recorder,
    port: platform,
    presigned_markers: ["X-Amz-Signature=", "X-Amz-Expires=60"],
  }
  @contract.run_contract(fixture)
  presigned_direct_upload(transport, sdk, platform, bucket, prefix)
  let left = residue(sdk, bucket, prefix)
  let parts = recorder.part_rows() catch {
    error => fail("part_rows: " + error_name(error))
  }
  let rows = @fs.readdir(root) catch {
    error => fail("readdir: " + error.to_string())
  }
  let _ = @fs.rmdir(root, recursive=true) catch {
    error => println("cleanup " + root + " raised " + error.to_string())
  }
  // The contract deletes what it writes, so a non-zero listing here is a leak in
  // the shared bucket rather than a test-detail problem.
  assert_eq(left, 0)
  // 主记录 + 分片子记录两份，且分片子记录要被门面清干净（完成与放弃各清一次）。
  assert_eq(rows.length(), 2)
  assert_eq(parts.length(), 0)
}

///|
fn error_name(error : @model.StorageError) -> String {
  match error {
    @model.StorageError::InvalidInput(detail) => "InvalidInput: " + detail
    @model.StorageError::NotSupported(detail) => "NotSupported: " + detail
    @model.StorageError::NotFound(detail) => "NotFound: " + detail
    @model.StorageError::Platform(detail) => "Platform: " + detail
    @model.StorageError::Recorder(detail) => "Recorder: " + detail
  }
}

///|
async test "s3 platform walks the shared contract against MinIO" {
  match live_env() {
    None => report_skip()
    Some(environment) =>
      run_minio(
        environment.0,
        environment.1,
        environment.2,
        environment.3,
        environment.4,
      )
  }
}

///|
/// The `acl: true` arm of the contract needs an endpoint that takes a canned ACL
/// write, and the two MinIO deployments measured this round are not one (the SDK
/// leg `live_acl_minio_test.mbt` records why: `PUT /key?acl` answers
/// `NotImplemented` while the same request with a broken secret answers
/// `SignatureDoesNotMatch`). So the positive arm runs against a one-shot local
/// S3 endpoint given by `S3_ACL_ENDPOINT`, which does honour the write —
/// pre-checked out-of-band before this leg was written.
///
/// Boundaries of that vehicle, stated so no reading is over-claimed: it does not
/// verify signatures, so this leg proves the client shape and the port's
/// accept-path only. It runs `case_acl_claim` plus the policy-document read-back,
/// not the whole contract — the full body stays on the MinIO and local legs.

///|
fn acl_env() -> (String, String, String)? {
  let endpoint = @env.get_env_var("S3_ACL_ENDPOINT")
  let access_key = @env.get_env_var("S3_ACL_AK")
  let secret_key = @env.get_env_var("S3_ACL_SK")
  match (endpoint, access_key, secret_key) {
    (Some(e), Some(a), Some(s)) => Some((e, a, s))
    _ => None
  }
}

///|
fn report_acl_skip() -> Unit {
  let names : Array[String] = ["S3_ACL_ENDPOINT", "S3_ACL_AK", "S3_ACL_SK"]
  let missing : Array[String] = []
  for name in names {
    if @env.get_env_var(name) is None {
      missing.push(name)
    }
  }
  println("SKIP ACL-capable contract leg, environment not supplied")
  println("missing: " + missing.join(", "))
  println(
    "SKIP IS NOT A PASS: the contract's acl:true arm was not executed by this run.",
  )
}

///|
/// Sweep everything the run put in its own bucket, reporting the count so "the
/// bucket was already empty" cannot pass as cleanup. The bucket drop afterwards
/// is the independent recompute: an endpoint refuses to delete a non-empty
/// bucket, so a 404 on the follow-up HEAD is the only reading that says nothing
/// of this run was left behind.
async fn acl_sweep(sdk : @sdk.Client, bucket : String) -> Unit {
  let listing = sdk.list_objects({
    bucket,
    prefix: None,
    delimiter: None,
    continuation_token: None,
    max_keys: Some(1000),
  }) catch {
    error => fail("list " + bucket + " for sweep: " + s3_reading(error))
  }
  let swept = listing.objects.length()
  println("acl leg swept " + swept.to_string() + " leftover object(s)")
  for object in listing.objects {
    let _ = sdk.delete_object({ bucket, key: object.key, }) catch {
      error => fail("sweep " + object.key + ": " + s3_reading(error))
    }
  }
  let _ = sdk.delete_bucket({ bucket, }) catch {
    error => fail("delete_bucket " + bucket + ": " + s3_reading(error))
  }
  let gone = sdk.bucket_exists({ bucket, }) catch {
    error => fail("bucket_exists " + bucket + ": " + s3_reading(error))
  }
  assert_true(!gone.exists)
}

///|
async fn run_acl_capable(
  endpoint : String,
  access_key : String,
  secret_key : String,
) -> Unit {
  let stamps = @sdk.utc_stamps(@env.now().reinterpret_as_int64())
  let bucket = "moonfs-acl-" + stamps.0
  let prefix = "moonfs-acl-contract"
  let platform_name = "acl-1"
  let transport = @transport.AsyncHttpTransport::new()
  let config = @sdk.Config::new(
    endpoint,
    "us-east-1",
    @sigv4.Credentials::new(access_key, secret_key),
  )
  let sdk = @sdk.Client::new(config, transport)
  let _ = sdk.create_bucket({ bucket, }) catch {
    error => fail("create_bucket " + bucket + ": " + s3_reading(error))
  }
  let domain = endpoint + "/" + bucket + "/" + prefix
  let platform = @s3.S3Platform::new(@s3.S3PlatformConfig::{
    platform: platform_name,
    bucket,
    base_path: "",
    supports_acl: true,
    domain: Some(domain),
    client: sdk,
  })
  let root = @fs.tmpdir(prefix="moonfs-contract-acl") catch {
    error => fail("tmpdir: " + error.to_string())
  }
  let _ = @fs.mkdir(root, recursive=true, allow_exist=true) catch {
    error => fail("mkdir: " + error.to_string())
  }
  let recorder = @record.FileRecorder::new(@record.FileRecorderConfig::{
    root_dir: root,
  })
  let service = @storage.Service::new([platform], recorder)
  let fixture = @contract.Fixture::{
    label: "acl-capable",
    platform: platform_name,
    base_path: prefix,
    domain,
    service,
    recorder,
    port: platform,
    presigned_markers: ["X-Amz-Signature=", "X-Amz-Expires=60"],
  }
  @contract.case_acl_claim(fixture)
  acl_effect_proof(platform, sdk, platform_name, bucket, prefix)
  let left = residue(sdk, bucket, prefix)
  let _ = @fs.rmdir(root, recursive=true) catch {
    error => println("cleanup " + root + " raised " + error.to_string())
  }
  assert_eq(left, 0)
  acl_sweep(sdk, bucket)
}

///|
async test "an endpoint that takes canned ACL writes passes the acl:true arm" {
  match acl_env() {
    None => report_acl_skip()
    Some(environment) =>
      run_acl_capable(environment.0, environment.1, environment.2)
  }
}
