require 'minitest/autorun'
require 'fileutils'
require 'open3'
require 'tmpdir'

REPO_ROOT = File.expand_path('..', __dir__)

describe 'install.sh' do
  before do
    @tmpdir = Dir.mktmpdir
    @srcdir = File.join(@tmpdir, 'src')
    @appdir = File.join(@tmpdir, 'app')

    FileUtils.mkdir_p(@srcdir)
    %w[install.sh portfwd.service.erb lib tools].each do |name|
      FileUtils.cp_r(File.join(REPO_ROOT, name), @srcdir)
    end
    FileUtils.mkdir_p(File.join(@srcdir, '.ssh'))
    write_src('.ssh/config.erb', "# USER_CONFIG_MARKER\nIdentityFile <%= ssh_dir %>/id_rsa\n")
    write_src('.ssh/id_rsa', "dummy key\n")
    write_src('.ssh/config.rb', "p_conn(host: 'portfwd', check_tcps: [])\n")
  end

  after do
    FileUtils.remove_entry(@tmpdir)
  end

  def write_src(path, content)
    File.write(File.join(@srcdir, path), content)
  end

  def run_install(extra_env = {})
    env = {
      'ARG_USE_SUDO' => 'false',
      'ARG_USE_ANOTHER_USER' => 'false',
      'ARG_ALWAYS_YES' => 'true',
      'ARG_INSTALL_SYSTEMD' => 'false',
      'ARG_APPDIR' => @appdir
    }.merge(extra_env)
    # install.sh must be invoked by absolute path (see code review 08)
    _out, status = Open3.capture2e(env, 'bash', File.join(@srcdir, 'install.sh'))
    status
  end

  def mode(path)
    File.stat(path).mode & 0o7777
  end

  def app_path(*names)
    File.join(@appdir, *names)
  end

  it 'should render the user config from .ssh/config.erb' do
    assert(run_install.success?)
    config = File.read(app_path('.ssh', 'config'))
    assert_includes(config, 'USER_CONFIG_MARKER')
    assert_includes(config, "IdentityFile #{@appdir}/.ssh/id_rsa")
  end

  it 'should install files with restricted permissions' do
    assert(run_install.success?)

    assert_equal(0o755, mode(@appdir))
    assert_equal(0o700, mode(app_path('.ssh')))
    %w[id_rsa config config.rb].each do |name|
      assert_equal(0o600, mode(app_path('.ssh', name)), name)
    end
    assert_equal(0o755, mode(app_path('lib')))
    Dir.glob(app_path('lib', '*')).each do |path|
      assert_equal(0o644, mode(path), path)
    end
  end

  it 'should not leave unnecessary files' do
    assert(run_install.success?)

    assert(!File.exist?(app_path('.ssh', 'config.erb')))
    assert(!File.exist?(app_path('portfwd.service')))
    assert_empty(Dir.glob(app_path('*.{new,old}'), File::FNM_DOTMATCH))
  end

  it 'should replace deployed files on rerun' do
    assert(run_install.success?)
    File.write(app_path('lib', 'stale.rb'), '')
    File.write(app_path('portfwd.service'), '')
    write_src('.ssh/config.erb', "# UPDATED_MARKER\n")

    assert(run_install.success?)
    assert(!File.exist?(app_path('lib', 'stale.rb')))
    assert(!File.exist?(app_path('portfwd.service')))
    assert_includes(File.read(app_path('.ssh', 'config')), 'UPDATED_MARKER')
  end

  it 'should recover from leftovers of an interrupted run' do
    assert(run_install.success?)
    FileUtils.mkdir_p(app_path('.ssh.new'))
    File.write(app_path('.ssh.new', 'stale'), '')
    FileUtils.mkdir_p(app_path('lib.old'))

    assert(run_install.success?)
    assert(!File.exist?(app_path('.ssh', 'stale')))
    assert_empty(Dir.glob(app_path('*.{new,old}'), File::FNM_DOTMATCH))
  end

  it 'should restore a directory left half-swapped' do
    assert(run_install.success?)
    FileUtils.mv(app_path('.ssh'), app_path('.ssh.old'))
    write_src('.ssh/config.erb', "<%= undefined_variable %>\n")

    assert(!run_install.success?)
    assert(File.exist?(app_path('.ssh', 'config')))
  end

  it 'should fail before installing when the runtime ruby does not exist' do
    status = run_install('ARG_INSTALL_SYSTEMD' => 'true', 'ARG_RUBY' => File.join(@tmpdir, 'no-ruby'))

    assert(!status.success?)
    assert(!File.exist?(@appdir))
  end

  it 'should clean up staging directories on failure' do
    write_src('.ssh/config.erb', "<%= undefined_variable %>\n")

    assert(!run_install.success?)
    assert(!File.exist?(app_path('.ssh.new')))
    assert(!File.exist?(app_path('.ssh')))
  end
end
