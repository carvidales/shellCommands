ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"
require "tmpdir"

module ActiveSupport
  class TestCase
    # Run tests in parallel with specified workers
    parallelize(workers: :number_of_processors)

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    # Point scripts and their working folder at throwaway dirs so tests never
    # touch the real scripts/ folder or the user's home.
    setup do
      @original_scripts_dir = Rails.configuration.x.scripts_dir
      @original_script_cwd = Rails.configuration.x.script_cwd
      @tmp_root = Dir.mktmpdir("script-runner-test")
      Rails.configuration.x.scripts_dir = Pathname(@tmp_root).join("scripts")
      Rails.configuration.x.script_cwd = File.join(@tmp_root, "cwd").tap { |dir| FileUtils.mkdir_p(dir) }
    end

    teardown do
      Rails.configuration.x.scripts_dir = @original_scripts_dir
      Rails.configuration.x.script_cwd = @original_script_cwd
      FileUtils.rm_rf(@tmp_root)
    end

    def scripts_dir = Rails.configuration.x.scripts_dir
  end
end
