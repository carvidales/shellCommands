class AddProcessIdentityToRuns < ActiveRecord::Migration[8.1]
  def change
    add_column :runs, :process_start_token, :string
    add_column :runs, :server_start_token, :string
  end
end
