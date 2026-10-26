require 'minitest/autorun'
require 'erb'

require_relative '../tools/lib/config_dsl'

SAMPLE_SSH_DIR = File.expand_path('../ssh', __dir__)

# the sample config.rb and config.erb should work together as they are
describe 'sample config' do
  # { host => { local: [ports], remote: [ports] } } of the Hosts in config.erb
  def ssh_hosts
    text = ERB.new(File.read(File.join(SAMPLE_SSH_DIR, 'config.erb')), trim_mode: '-')
              .result_with_hash(ssh_dir: '/ssh_dir')
    hosts = {}
    current = nil
    text.each_line do |line|
      key, value = line.strip.split(/\s+/, 3)
      case key
      when 'Host'
        current = hosts[value] = { local: [], remote: [] }
      when 'LocalForward'
        current[:local] << Integer(value)
      when 'RemoteForward'
        current[:remote] << Integer(value)
      end
    end
    hosts
  end

  def nodes
    ConfigDSL.load_file(File.join(SAMPLE_SSH_DIR, 'config.rb'))
  end

  it 'should declare the hosts of config.rb in config.erb' do
    nodes.each do |node|
      assert_includes(ssh_hosts.keys, node.host)
    end
  end

  it 'should check the LocalForward ports of the same Host' do
    hosts = ssh_hosts
    nodes.each do |node|
      local_checks = node.info[:check_tcps].select { |check_tcp| check_tcp[:host] == 'localhost' }
      refute_empty(local_checks, node.host)
      local_checks.each do |check_tcp|
        assert_includes(hosts[node.host][:local], check_tcp[:port], node.host)
      end
    end
  end

  it 'should listen on different ports by RemoteForward and LocalForward' do
    hosts = ssh_hosts
    remote_ports = hosts.values.flat_map { |host| host[:remote] }
    local_ports = hosts.values.flat_map { |host| host[:local] }
    assert_equal(remote_ports.uniq, remote_ports)
    assert_equal(local_ports.uniq, local_ports)
  end

  it 'should not offer a way to disable host key verification' do
    text = File.read(File.join(SAMPLE_SSH_DIR, 'config.erb'))
    refute_match(/StrictHostKeyChecking\s+no/, text)
    refute_match(%r{UserKnownHostsFile\s+/dev/null}, text)
  end
end
