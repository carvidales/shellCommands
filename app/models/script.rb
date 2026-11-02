# A user script. The record holds the name; the code lives in
# scripts/<name>.sh, which is the source of truth (see the design doc).
class Script < ApplicationRecord
  NAME_FORMAT = /\A[a-zA-Z0-9_-]+\z/
  PARAMETER_FORMAT = /\A# @param ([A-Za-z][A-Za-z0-9_]*)=([^\r\n]*)\z/
  MAX_PARAMETERS = 10
  MAX_ARGUMENT_BYTES = 1024
  class ParameterError < StandardError; end

  has_many :runs, -> { order(started_at: :desc) }, dependent: :destroy

  validates :name, presence: true, uniqueness: true,
    format: { with: NAME_FORMAT, message: "can only contain letters, numbers, - and _" }
  validate :target_file_is_free, if: :writing_new_path?

  before_destroy :ensure_not_running, prepend: true
  after_save :write_file
  after_destroy_commit :delete_file

  # Browsers submit textareas with CRLF line endings, which break bash.
  def code=(value)
    @code = value&.gsub("\r\n", "\n")
  end

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

  # Metadata is kept in the shell file rather than the database.
  # Lines such as '# @param PORT=3000' define ordered $1, $2, ... arguments.
  def parameters
    definitions = code.lines.filter_map do |line|
      match = PARAMETER_FORMAT.match(line.chomp)
      { name: match[1], default: match[2] } if match
    end
    raise ParameterError, "Maximum #{MAX_PARAMETERS} parameters per script" if definitions.length > MAX_PARAMETERS
    raise ParameterError, "Duplicate parameter names" if definitions.map { |param| param[:name] }.uniq.length != definitions.length
    raise ParameterError, "Parameter defaults must be at most #{MAX_ARGUMENT_BYTES} bytes" if definitions.any? { |param| param[:default].bytesize > MAX_ARGUMENT_BYTES }
    definitions
  end

  def arguments_for(values)
    definitions = parameters
    raise ParameterError, "Parameter values are required" unless values.respond_to?(:permit!) && values.respond_to?(:to_unsafe_h)
    supplied = values.to_unsafe_h
    raise ParameterError, "Unexpected parameter" unless (supplied.keys - definitions.map { |param| param[:name] }).empty?
    definitions.map do |definition|
      value = supplied.fetch(definition[:name], definition[:default])
      raise ParameterError, "Invalid value for #{definition[:name]}" unless value.is_a?(String) && value.bytesize <= MAX_ARGUMENT_BYTES && !value.include?("\u0000")
      value
    end
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
    write_atomically(@code) unless @code.nil?
    File.chmod(0o755, path) if File.exist?(path)
  end

  # bash reads a script as it runs, so swap in a new file rather than
  # rewriting the one a running script may be reading.
  def write_atomically(content)
    temp_path = self.class.directory.join(".#{name}.sh.#{SecureRandom.hex(4)}.tmp")
    File.write(temp_path, content)
    File.rename(temp_path, path)
  ensure
    FileUtils.rm_f(temp_path) if temp_path
  end

  def delete_file
    FileUtils.rm_f(path)
  end
end
