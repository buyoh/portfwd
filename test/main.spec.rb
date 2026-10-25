require 'minitest/autorun'
require 'rbconfig'
require 'tmpdir'

MAIN_RB_PATH = File.expand_path('../lib/main.rb', __dir__)

describe 'main.rb' do
  it 'should exit with 1 when the app thread fails' do
    Dir.mktmpdir do |dir|
      # missing check_tcps makes the app thread fail after spawning ssh (or ssh itself fails to spawn)
      File.write(File.join(dir, 'config.rb'), "p_conn(host: 'portfwd-test-nonexistent')\n")
      File.write(File.join(dir, 'config'), '')

      pid = spawn(RbConfig.ruby, MAIN_RB_PATH, dir, out: File::NULL, err: File::NULL)
      status = nil
      200.times do
        _, status = Process.wait2(pid, Process::WNOHANG)
        break if status

        sleep 0.1
      end
      unless status
        Process.kill('KILL', pid)
        Process.wait(pid)
        flunk('main.rb did not exit (hang)')
      end
      assert_equal(1, status.exitstatus)
    end
  end
end
