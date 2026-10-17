///|
pub(open) trait Recorder {
  async fn save(Self, @model.FileInfo) -> Bool raise @model.StorageError
  async fn update(Self, @model.FileInfo) -> Unit raise @model.StorageError
  async fn get_by_url(Self, String) -> @model.FileInfo? raise @model.StorageError
  async fn delete(Self, String) -> Bool raise @model.StorageError
  async fn save_file_part(Self, @model.FilePartInfo) -> Unit raise @model.StorageError
  async fn delete_file_part_by_upload_id(Self, String) -> Unit raise @model.StorageError
}
