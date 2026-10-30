# One execution of a script. The log is appended as output arrives and
# streamed to anyone watching the run page.
class Run < ApplicationRecord
  STATUSES = %w[running succeeded failed stopped].freeze

  belongs_to :script

  validates :status, inclusion: { in: STATUSES }

  def running? = status == "running"

  def duration
    return unless started_at
    (finished_at || Time.current) - started_at
  end

  # Concatenates in SQL so concurrent appends never overwrite each other.
  def append_log!(chunk)
    self.class.where(id: id).update_all([ "log = log || ?", chunk ])
    broadcast_append_to self, target: "run_#{id}_log", html: ERB::Util.html_escape(chunk)
  end

  def finish!(status:, exit_code: nil, note: nil)
    append_log!(note) if note
    update!(status: status, exit_code: exit_code, finished_at: Time.current, pid: nil)
    broadcast_replace_to self, target: "run_#{id}_status", partial: "runs/status", locals: { run: self }
  end
end
