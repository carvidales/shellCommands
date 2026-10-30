# A user script. The record holds the name; the code lives in
# scripts/<name>.sh, which is the source of truth (see the design doc).
class Script < ApplicationRecord
  NAME_FORMAT = /\A[a-zA-Z0-9_-]+\z/

  has_many :runs, -> { order(started_at: :desc) }, dependent: :destroy

  validates :name, presence: true, uniqueness: true,
    format: { with: NAME_FORMAT, message: "can only contain letters, numbers, - and _" }
  validate :target_file_is_free, if: :writing_new_path?

  before_destroy :ensure_not_running, prepend: true
  after_save :write_file
  after_destroy_commit :delete_file

  attr_writer :code

  def self.directory = Rails.configuration.x.scripts_dir

  # Creates a record for every scripts/*.sh file that doesn't have one yet,
  # so scripts created outside the app show up as buttons.
  def self.sync_from_directory!
    names = Dir.glob(directory.join("*.sh")).map { |file| File.basename(file, ".sh") }
    (names.grep(NAME_FORMAT) - pluck(:name)).each { |name| create!(name: name) }
  end

  def self.path_for(name) = directory.join("#{name}.sh")

  def path = self.class.path_for(name)

  def code
    @code ||= file_missing? ? "" : File.read(path)
  end

  def running? = runs.where(status: "running").exists?

  def last_run = runs.first

  def file_missing?
    !File.exist?(path)
  end

  private

  # Only creating or renaming a script from the app writes a new file; refuse
  # to clobber an untracked file that happens to sit at the target path.
  def writing_new_path?
    name.to_s.match?(NAME_FORMAT) && (new_record? ? !@code.nil? : will_save_change_to_name?)
  end

  def target_file_is_free
    errors.add(:name, "is already used by a file in the scripts folder") if File.exist?(path)
  end

  def ensure_not_running
    return unless running?
    errors.add(:base, "Can't delete a running script")
    throw :abort
  end

  def write_file
    FileUtils.mkdir_p(self.class.directory)
    if saved_change_to_name? && name_before_last_save
      old_path = self.class.path_for(name_before_last_save)
      File.rename(old_path, path) if File.exist?(old_path)
    end
    File.write(path, @code) unless @code.nil?
    File.chmod(0o755, path) if File.exist?(path)
  end

  def delete_file
    FileUtils.rm_f(path)
  end
end
