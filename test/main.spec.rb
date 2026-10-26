require 'minitest/autorun'
require 'rbconfig'
require 'tmpdir'
require 'open3'
require 'socket'

MAIN_RB_PATH = File.expand_path('../lib/main.rb', __dir__)

describe 'main.rb' do
  it 'should exit with 1 when the app thread fails' do
    Dir.mktmpdir do |dir|
      # a port which is closed: the check of the connection fails after spawning ssh (or ssh itself fails to spawn)
      server = TCPServer.new('127.0.0.1', 0)
      port = server.addr[1]
      server.close
      File.write(File.join(dir, 'config.yml'), <<~YAML)
        version: 1
        nodes:
        - host: portfwd-test-nonexistent
          check_tcps:
          - host: 127.0.0.1
            port: #{port}
      YAML
      File.write(File.join(dir, 'config'), '')

      pid = spawn(RbConfig.ruby, MAIN_RB_PATH, dir, out: File::NULL, err: File::NULL)
      status = nil
      # the check of the connection takes about 10 seconds
      300.times do
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

  it 'should exit with 1 when config.yml is invalid' do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'config.yml'), "version: 1\nnodes: [\n")

      out, status = Open3.capture2e(RbConfig.ruby, MAIN_RB_PATH, dir)
      assert_equal(1, status.exitstatus)
      assert_includes(out, 'Invalid config')
      assert_includes(out, File.join(dir, 'config.yml'))
    end
  end

  it 'should not evaluate config.rb' do
    Dir.mktmpdir do |dir|
      marker = File.join(dir, 'evaluated')
      File.write(File.join(dir, 'config.rb'), "File.write(#{marker.inspect}, '')\np_conn(host: 'portfwd', check_tcps: [])\n")

      out, status = Open3.capture2e(RbConfig.ruby, MAIN_RB_PATH, dir)
      assert_equal(1, status.exitstatus)
      assert_includes(out, 'tools/generate_config.rb')
      assert(!File.exist?(marker))
    end
  end
end
