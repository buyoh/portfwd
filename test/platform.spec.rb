require 'minitest/autorun'
require 'logger'

require_relative '../lib/platform'

Platform = PlatformStub

describe 'Platform' do
  before do
    @logger ||= Logger.new(nil)
    @platform = Platform.new(@logger)
  end

  after do
    @platform.terminate
  end

  it 'should work `is_alive_child_process`' do
    @platform.add_ssh_host_to_tcp_host_for_test('host0', 'tcp0', 8000)

    pid = @platform.start_child_process_ssh('host0', 'fixtures/ssh_config')
    assert(pid)
    assert(@platform.is_alive_child_process(pid))

    @platform.kill_child_process(pid)
    alive = true
    9.times do
      unless @platform.is_alive_child_process(pid)
        alive = false
        break
      end
      sleep 0.1
    end
    assert(!alive)
  end

  it 'should work `wait_tcp_port_is_open`' do
    @platform.add_ssh_host_to_tcp_host_for_test('host0', 'tcp0', 8000)
    @platform.add_ssh_host_to_tcp_host_for_test('host0', 'tcp0', 8001)
    @platform.add_ssh_host_to_tcp_host_for_test('host1', 'tcp1', 8000)

    pid = @platform.start_child_process_ssh('host0', 'fixtures/ssh_config')
    assert(pid)
    assert(@platform.is_alive_child_process(pid))

    assert(@platform.wait_tcp_port_is_open('tcp0', 8000, pid))
    assert(@platform.wait_tcp_port_is_open('tcp0', 8001, pid))

    assert(!@platform.wait_tcp_port_is_open('tcp1', 8000, pid, 1))

    assert(@platform.check_pid_and_tcp_port_is_open('tcp0', 8000, pid))
    assert(@platform.check_pid_and_tcp_port_is_open('tcp0', 8001, pid))

    @platform.kill_child_process(pid)
    alive = true
    9.times do
      unless @platform.is_alive_child_process(pid)
        alive = false
        break
      end
      sleep 0.1
    end
    assert(!alive)

    assert(!@platform.check_pid_and_tcp_port_is_open('tcp0', 8000, pid))
    assert(!@platform.check_pid_and_tcp_port_is_open('tcp0', 8001, pid))
  end
end
