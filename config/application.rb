require_relative "boot"

require "rails"
# Pick the frameworks you want:
require "active_model/railtie"
require "active_job/railtie"
require "active_record/railtie"
# require "active_storage/engine"
require "action_controller/railtie"
# require "action_mailer/railtie"
# require "action_mailbox/engine"
# require "action_text/engine"
require "action_view/railtie"
require "action_cable/engine"
require "rails/test_unit/railtie"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module ShellCommands
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 8.1

    # Please, add to the `ignore` list any other `lib` subdirectories that do
    # not contain `.rb` files, or that should not be reloaded or eager loaded.
    # Common ones are `templates`, `generators`, or `middleware`, for example.
    config.autoload_lib(ignore: %w[assets tasks script_runner.rb])

    # Configuration for the application, engines, and railties goes here.
    #
    # These settings can be overridden in specific environments using the files
    # in config/environments, which are processed later.
    #
    # config.time_zone = "Central Time (US & Canada)"
    # config.eager_load_paths << Rails.root.join("extras")

    # Don't generate system test files.
    config.generators.system_tests = nil

    # Where user scripts live and where they run from.
    config.x.scripts_dir = Rails.root.join("scripts")
    config.x.script_cwd = Dir.home
    config.x.execution_timeout = Float(ENV.fetch("SCRIPT_TIMEOUT_SECONDS", "600"))
    config.x.max_concurrent_runs = Integer(ENV.fetch("SCRIPT_MAX_CONCURRENT_RUNS", "8"))
    raise "SCRIPT_MAX_CONCURRENT_RUNS must be positive" unless config.x.max_concurrent_runs.positive?
    config.x.max_log_bytes = Integer(ENV.fetch("SCRIPT_MAX_LOG_BYTES", "5242880"))
    raise "SCRIPT_TIMEOUT_SECONDS must be positive and finite" unless config.x.execution_timeout.positive? && config.x.execution_timeout.finite?
    raise "SCRIPT_MAX_LOG_BYTES must be at least 1024" unless config.x.max_log_bytes >= 1024
  end
end
