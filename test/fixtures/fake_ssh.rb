# Fake ssh command for PlatformImpl tests. Arguments are ignored.
#   FAKE_SSH_IGNORE_TERM=1     ignore SIGTERM
#   FAKE_SSH_EXIT_AFTER=<sec>  exit by itself after <sec> seconds
#   FAKE_SSH_SIGNAL_LOG=<path> append received signal names to <path>
#   FAKE_SSH_READY_FILE=<path> create <path> after signal handlers are installed

log_path = ENV['FAKE_SSH_SIGNAL_LOG']
log_signal = ->(name) { File.open(log_path, 'a') { |f| f.puts(name) } if log_path }

if ENV['FAKE_SSH_IGNORE_TERM'] == '1'
  Signal.trap('TERM') { log_signal.call('TERM') }
else
  Signal.trap('TERM') do
    log_signal.call('TERM')
    exit 0
  end
end

ready_path = ENV['FAKE_SSH_READY_FILE']
File.write(ready_path, '') if ready_path

exit_after = ENV['FAKE_SSH_EXIT_AFTER']
if exit_after
  sleep exit_after.to_f
else
  sleep
end
