require Rails.root.join("lib/script_runner").to_s

# Only the server owns script processes. Consoles, migrations, and tests must
# not touch runs a live server is executing.
Rails.application.config.after_initialize do
  if defined?(Rails::Server)
    ScriptRunner.recover_orphans!
    at_exit { ScriptRunner.stop_all }
  end
end
