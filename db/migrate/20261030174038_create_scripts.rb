class CreateScripts < ActiveRecord::Migration[8.1]
  def change
    create_table :scripts do |t|
      t.string :name, null: false
      t.timestamps
    end
    add_index :scripts, :name, unique: true
  end
end
