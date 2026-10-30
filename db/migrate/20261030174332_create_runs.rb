class CreateRuns < ActiveRecord::Migration[8.1]
  def change
    create_table :runs do |t|
      t.references :script, null: false, foreign_key: true
      t.string :status, null: false, default: "running"
      t.integer :exit_code
      t.datetime :started_at, null: false
      t.datetime :finished_at
      t.text :log, null: false, default: ""
      t.integer :pid
      t.text :code_snapshot, null: false
      t.timestamps
    end
  end
end
