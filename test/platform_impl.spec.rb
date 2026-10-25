require 'minitest/autorun'
require 'logger'
require 'rbconfig'
require 'tmpdir'

require_relative '../lib/platform'

FAKE_SSH_PATH = File.expand_path('fixtures/fake_ssh.rb', __dir__)

describe 'PlatformImpl' do
  def fake_ssh_command(env = {})
    ['env', *env.map { |k, v| "#{k}=#{v}" }, RbConfig.ruby, FAKE_SSH_PATH]
  end

  def new_platform(env = {})
    PlatformImpl.new(@logger, ssh_command: fake_ssh_command(env), kill_timeout_sec: 0.5)
  end

  def reaped?(pid)
    Process.waitpid(pid, Process::WNOHANG)
    false
  rescue Errno::ECHILD
    true
  end

  def wait_until(timeout_sec = 3)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout_sec
    until yield
      return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      sleep 0.05
    end
    true
  end

  before do
    @logger ||= Logger.new(nil)
    @tmpdir = Dir.mktmpdir
    @platforms = []
  end

  after do
    @platforms.each(&:terminate)
    FileUtils.remove_entry(@tmpdir)
  end

  it 'should start a child process and report it alive' do
    platform = new_platform
    @platforms << platform

    pid = platform.start_child_process_ssh('host0', 'config')
    assert(pid)
    assert(platform.is_alive_child_process(pid))
  end

  it 'should stop a child by TERM and reap it' do
    log_path = File.join(@tmpdir, 'signal.log')
    ready_path = File.join(@tmpdir, 'ready')
    platform = new_platform('FAKE_SSH_SIGNAL_LOG' => log_path, 'FAKE_SSH_READY_FILE' => ready_path)
    @platforms << platform

    pid = platform.start_child_process_ssh('host0', 'config')
    # wait until the fake ssh installs its signal handler
    assert(wait_until(10) { File.exist?(ready_path) })
    platform.kill_child_process(pid)

    assert(reaped?(pid))
    assert(!platform.is_alive_child_process(pid))
    assert_equal(['TERM'], File.readlines(log_path, chomp: true))
  end

  it 'should stop a child ignoring TERM by KILL' do
    ready_path = File.join(@tmpdir, 'ready')
    platform = new_platform('FAKE_SSH_IGNORE_TERM' => '1', 'FAKE_SSH_READY_FILE' => ready_path)
    @platforms << platform

    pid = platform.start_child_process_ssh('host0', 'config')
    assert(wait_until(10) { File.exist?(ready_path) })
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    platform.kill_child_process(pid)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert(reaped?(pid))
    assert(elapsed >= 0.5)
  end

  it 'should reap a child which exited by itself' do
    platform = new_platform('FAKE_SSH_EXIT_AFTER' => '0.1')
    @platforms << platform

    pid = platform.start_child_process_ssh('host0', 'config')
    assert(wait_until { !platform.is_alive_child_process(pid) })
    assert(reaped?(pid))
  end

  it 'should not touch a process which is not its child' do
    platform = new_platform
    @platforms << platform

    killed = []
    original_kill = Process.method(:kill)
    Process.define_singleton_method(:kill) { |*args| killed << args }
    begin
      assert(!platform.is_alive_child_process(Process.ppid))
      platform.kill_child_process(Process.ppid)
    ensure
      Process.define_singleton_method(:kill, original_kill)
    end
    assert_empty(killed)
  end

  it 'should return nil when the command does not exist' do
    platform = PlatformImpl.new(@logger, ssh_command: ['/nonexistent/ssh'], kill_timeout_sec: 0.5)
    @platforms << platform

    assert_nil(platform.start_child_process_ssh('host0', 'config'))
  end

  it 'should stop all children by `terminate`' do
    platform = new_platform

    pids = 2.times.map { platform.start_child_process_ssh('host0', 'config') }
    platform.terminate

    pids.each { |pid| assert(reaped?(pid)) }
  end

  it 'should return false from `check_pid_and_tcp_port_is_open` for a dead child' do
    server = TCPServer.new('127.0.0.1', 0)
    port = server.addr[1]
    platform = new_platform('FAKE_SSH_EXIT_AFTER' => '0.1')
    @platforms << platform

    pid = platform.start_child_process_ssh('host0', 'config')
    assert(platform.check_pid_and_tcp_port_is_open('127.0.0.1', port, pid))
    assert(wait_until { !platform.check_pid_and_tcp_port_is_open('127.0.0.1', port, pid) })
    assert(reaped?(pid))
  ensure
    server&.close
  end
end
