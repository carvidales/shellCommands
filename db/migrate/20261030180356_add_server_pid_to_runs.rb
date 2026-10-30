class AddServerPidToRuns < ActiveRecord::Migration[8.1]
  def change
    add_column :runs, :server_pid, :integer
  end
end
