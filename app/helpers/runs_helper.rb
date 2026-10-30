module RunsHelper
  STATUS_ICONS = { "running" => "●", "succeeded" => "✅", "failed" => "❌", "stopped" => "⏹" }.freeze

  def run_status_icon(run) = STATUS_ICONS.fetch(run.status)

  def format_duration(seconds)
    return "—" if seconds.nil?
    seconds < 60 ? "#{seconds.round(1)}s" : "#{(seconds / 60).floor}m #{(seconds % 60).round}s"
  end
end
