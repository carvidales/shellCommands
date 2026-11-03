class AddTerminationNoteToRuns < ActiveRecord::Migration[8.1]
  def change
    add_column :runs, :termination_note, :text
  end
end
