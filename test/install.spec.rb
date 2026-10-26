require 'minitest/autorun'
require 'fileutils'
require 'open3'
require 'rbconfig'
require 'tmpdir'

require_relative '../lib/node_config'

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

  # unset variables inherited from the developer's shell, which install.sh would reject or use
  CLEARED_ENV = %w[
    ARG_USE_SUDO ARG_USE_ANOTHER_USER ARG_UID ARG_USE_CURRENT_DIR ARG_INSTALL_SYSTEMD ARG_STARTUP_CHECK_SEC
    ARG_USER ARG_USE_ROOT ARG_RUBY
  ].to_h { |name| [name, nil] }.freeze

  # a nil value in extra_env unsets the variable
  def run_install_with_output(extra_env = {}, stdin: '')
    env = CLEARED_ENV.merge(
      'ARG_ALWAYS_YES' => 'true',
      'ARG_FILES_ONLY_FOR_TEST' => 'true',
      'ARG_APPDIR' => @appdir
    ).merge(extra_env)
    # install.sh must be invoked by absolute path (see code review 08)
    out, status = Open3.capture2e(env, 'bash', File.join(@srcdir, 'install.sh'), stdin_data: stdin)
    [status, out]
  end

  def run_install(extra_env = {})
    run_install_with_output(extra_env)[0]
  end

  # a sudo that runs the read-only check of install.sh (`sh -c`), and logs and fails anything else.
  # check: :run runs the check, :fail fails it as when the authentication fails, :garbage prints an unexpected output
  def install_fake_sudo(check: :run)
    bindir = File.join(@tmpdir, 'bin')
    FileUtils.mkdir_p(bindir)
    path = File.join(bindir, 'sudo')
    File.write(path, <<~SH)
      #!/bin/sh
      if [ "$1" = sh ]; then
        # the script is multi-line
        echo "$1 $2" >> "$FAKE_SUDO_CHECK_LOG"
        case "$FAKE_SUDO_CHECK" in
          fail) exit 1 ;;
          garbage) echo garbage; exit 0 ;;
        esac
        exec "$@"
      fi
      echo "$*" >> "$FAKE_SUDO_LOG"
      exit 1
    SH
    File.chmod(0o755, path)
    @sudo_log = File.join(@tmpdir, 'sudo.log')
    @sudo_check_log = File.join(@tmpdir, 'sudo_check.log')
    { 'PATH' => "#{bindir}:#{ENV.fetch('PATH')}", 'FAKE_SUDO_LOG' => @sudo_log,
      'FAKE_SUDO_CHECK_LOG' => @sudo_check_log, 'FAKE_SUDO_CHECK' => check.to_s }
  end

  def read_log(path)
    File.exist?(path) ? File.readlines(path, chomp: true) : []
  end

  # calls other than the read-only check
  def sudo_calls
    read_log(@sudo_log)
  end

  def sudo_check_calls
    read_log(@sudo_check_log)
  end

  # normal mode (no ARG_FILES_ONLY_FOR_TEST) with the fake sudo, and a runtime ruby that exists on any host
  def normal_mode_env(check: :run)
    install_fake_sudo(check: check).merge('ARG_FILES_ONLY_FOR_TEST' => nil, 'ARG_RUBY' => RbConfig.ruby)
  end

  def git(*args)
    env = { 'GIT_CONFIG_GLOBAL' => '/dev/null', 'GIT_CONFIG_NOSYSTEM' => '1' }
    out, status = Open3.capture2e(env, 'git', '-c', 'user.name=test', '-c', 'user.email=test@example.com',
                                  '-C', @srcdir, *args)
    assert(status.success?, out)
    out
  end

  def git_available?
    system('git', '--version', out: File::NULL, err: File::NULL)
  end

  def mode(path)
    File.stat(path).mode & 0o7777
  end

  def app_path(*names)
    File.join(@appdir, *names)
  end

  def make_app_files(files)
    files.each do |name, content|
      FileUtils.mkdir_p(File.dirname(app_path(name)))
      File.write(app_path(name), content)
    end
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
    %w[id_rsa config config.yml].each do |name|
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
    env = install_fake_sudo.merge('ARG_FILES_ONLY_FOR_TEST' => nil, 'ARG_RUBY' => File.join(@tmpdir, 'no-ruby'))
    status, out = run_install_with_output(env)

    assert(!status.success?)
    assert_includes(out, 'is not an absolute path to an executable')
    assert(!File.exist?(@appdir))
    assert_empty(sudo_calls)
  end

  describe 'config.yml' do
    it 'should install config.yml generated from config.rb instead of config.rb' do
      assert(run_install.success?)
      assert(!File.exist?(app_path('.ssh', 'config.rb')))
      assert_equal(%w[portfwd], NodeConfig.parse_file(app_path('.ssh', 'config.yml')).map(&:host))
    end

    it 'should not install config.yml in the working copy' do
      write_src('.ssh/config.yml', "stale\n")
      write_src('.ssh/config.rb', "p_conn(host: 'updated', check_tcps: [])\n")
      assert(run_install.success?)
      assert_equal(%w[updated], NodeConfig.parse_file(app_path('.ssh', 'config.yml')).map(&:host))
    end

    it 'should not leave the temporary file' do
      tmpdir = File.join(@tmpdir, 'tmp')
      FileUtils.mkdir_p(tmpdir)
      assert(run_install('TMPDIR' => tmpdir).success?)
      write_src('.ssh/config.rb', "p_conn(host: 'a'\n")
      assert(!run_install('TMPDIR' => tmpdir).success?)
      assert_empty(Dir.children(tmpdir))
    end

    it 'should fail without modifying the destination when config.rb is invalid' do
      write_src('.ssh/config.rb', "p_conn(host: 'a', check_tcps: [], user: 'x')\n")
      status, out = run_install_with_output
      assert(!status.success?)
      assert_includes(out, 'Failed to generate config.yml')
      assert(!File.exist?(@appdir))

      write_src('.ssh/config.rb', "p_conn(host: 'portfwd', check_tcps: [])\n")
      assert(run_install.success?)
      File.write(app_path('lib', 'marker.rb'), '')
      write_src('.ssh/config.erb', "# UPDATED_MARKER\n")
      write_src('.ssh/config.rb', "p_conn(host: 'portfwd'\n")
      assert(!run_install.success?)
      assert(File.exist?(app_path('lib', 'marker.rb')))
      refute_includes(File.read(app_path('.ssh', 'config')), 'UPDATED_MARKER')
      assert_equal(%w[portfwd], NodeConfig.parse_file(app_path('.ssh', 'config.yml')).map(&:host))
    end

    it 'should fail without config.rb' do
      File.unlink(File.join(@srcdir, '.ssh', 'config.rb'))
      status, out = run_install_with_output
      assert(!status.success?)
      assert_includes(out, "'.ssh/config.rb' not found")
      assert(!File.exist?(@appdir))
    end

    it 'should evaluate config.rb without sudo before checking the destination' do
      write_src('.ssh/config.rb', "p_conn(host: 'a'\n")
      status, out = run_install_with_output(normal_mode_env)
      assert(!status.success?)
      assert_includes(out, 'Failed to generate config.yml')
      assert_empty(sudo_calls)
      assert_empty(sudo_check_calls)
      assert(!File.exist?(@appdir))
    end

    it 'should fail when config.rb ends the generator successfully without output' do
      write_src('.ssh/config.rb', "exit 0\n")
      assert(!run_install.success?)
      assert(!File.exist?(@appdir))
    end

    it 'should fail before installing when the runtime ruby cannot load yaml' do
      fake_ruby = File.join(@tmpdir, 'ruby-without-yaml')
      File.write(fake_ruby, "#!/bin/sh\nexit 1\n")
      File.chmod(0o755, fake_ruby)
      env = install_fake_sudo.merge('ARG_FILES_ONLY_FOR_TEST' => nil, 'ARG_RUBY' => fake_ruby)
      status, out = run_install_with_output(env)

      assert(!status.success?)
      assert_includes(out, 'cannot load yaml')
      assert(!File.exist?(@appdir))
      assert_empty(sudo_calls)
      assert_empty(sudo_check_calls)
    end
  end

  it 'should clean up staging directories on failure' do
    write_src('.ssh/config.erb', "<%= undefined_variable %>\n")

    assert(!run_install.success?)
    assert(!File.exist?(app_path('.ssh.new')))
    assert(!File.exist?(app_path('.ssh')))
  end

  describe 'arguments' do
    it 'should reject obsolete arguments with their replacement' do
      {
        'ARG_USE_SUDO' => 'sudo is used automatically',
        'ARG_USE_ANOTHER_USER' => 'ARG_USE_ROOT=true',
        'ARG_UID' => 'allocated automatically',
        'ARG_USE_CURRENT_DIR' => 'Run lib/main.rb directly',
        'ARG_INSTALL_SYSTEMD' => 'ARG_FILES_ONLY_FOR_TEST',
        'ARG_STARTUP_CHECK_SEC' => 'waits 20s'
      }.each do |name, replacement|
        status, out = run_install_with_output({ name => 'false' })
        assert(!status.success?, name)
        assert_includes(out, "#{name} is no longer supported")
        assert_includes(out, replacement)
      end
      assert(!File.exist?(@appdir))
    end

    it 'should reject obsolete arguments even with their old default values or empty' do
      assert(!run_install('ARG_USE_SUDO' => 'true').success?)
      assert(!run_install('ARG_INSTALL_SYSTEMD' => '').success?)
      assert(!File.exist?(@appdir))
    end

    it 'should reject a relative ARG_APPDIR' do
      assert(!run_install('ARG_APPDIR' => 'app').success?)
      assert(!File.exist?(File.join(@srcdir, 'app')))
    end

    it 'should reject an invalid ARG_USER' do
      ['-o root', "a\nb", 'a:b'].each do |user|
        assert(!run_install('ARG_USER' => user).success?, user.inspect)
      end
    end

    it 'should reject non-boolean values' do
      status, out = run_install_with_output({ 'ARG_USE_ROOT' => 'yes' })
      assert(!status.success?)
      assert_includes(out, 'ARG_USE_ROOT')
    end

    it 'should reject ARG_USER with ARG_USE_ROOT=true' do
      assert(!run_install('ARG_USE_ROOT' => 'true', 'ARG_USER' => 'foo').success?)
      assert(!File.exist?(@appdir))
    end

    it 'should refuse to install into the source directory' do
      assert(!run_install('ARG_APPDIR' => @srcdir).success?)
      assert(File.exist?(File.join(@srcdir, '.ssh', 'config.erb')))
      assert(File.exist?(File.join(@srcdir, 'lib', 'main.rb')))
    end
  end

  describe 'test mode' do
    it 'should not call sudo' do
      status, out = run_install_with_output(install_fake_sudo)
      assert(status.success?, out)
      assert_includes(out, 'TEST MODE:')
      assert_empty(sudo_calls)
      assert_empty(sudo_check_calls)
    end

    it 'should ignore ARG_USE_ROOT' do
      # answers only the first confirmation. A second one fails at EOF
      status, out = run_install_with_output({ 'ARG_ALWAYS_YES' => nil, 'ARG_USE_ROOT' => 'true' }, stdin: "Y\n")
      assert(status.success?, out)
      refute_includes(out, 'will run as root')
    end
  end

  describe 'normal mode' do
    before do
      skip 'requires a non-root user' if Process.euid.zero?
    end

    it 'should use sudo' do
      status, out = run_install_with_output(normal_mode_env)
      assert(!status.success?, out)
      refute_includes(out, 'TEST MODE:')
      assert_equal(['sh -c'], sudo_check_calls)
      refute_empty(sudo_calls)
      assert(!File.exist?(@appdir))
    end

    %i[fail garbage].each do |check|
      it "should abort when the check of the destination results in #{check}" do
        make_app_files('note.txt' => 'keep')
        status, out = run_install_with_output(normal_mode_env(check: check))
        assert(!status.success?, out)
        assert_includes(out, 'Failed to check')
        assert_equal(['sh -c'], sudo_check_calls)
        # nothing that modifies the system
        assert_empty(sudo_calls)
        assert(!File.exist?(app_path('version')))
      end
    end

    it 'should set the owner to the service user' do
      env = normal_mode_env.merge('ARG_USER' => 'portfwd-test-nonexistent')
      assert(!run_install(env).success?)
      assert_match(/\Auseradd .*portfwd-test-nonexistent\z/, sudo_calls.first)
    end

    it 'should not set the owner with ARG_USE_ROOT=true' do
      env = normal_mode_env.merge('ARG_USE_ROOT' => 'true')
      assert(!run_install(env).success?)
      assert_equal("install -d -m 755 #{@appdir}", sudo_calls.first)
    end
  end

  describe 'version file' do
    it 'should write unknown outside a git repository' do
      assert(run_install.success?)
      assert_equal("unknown\n", File.read(app_path('version')))
      assert_equal(0o644, mode(app_path('version')))
    end

    it 'should write the commit hash and time' do
      skip 'git is not available' unless git_available?
      git('init', '-q')
      git('add', '-A')
      git('commit', '-q', '-m', 'test')

      assert(run_install.success?)
      hash, time = File.readlines(app_path('version'), chomp: true)
      assert_equal(git('rev-parse', 'HEAD').strip, hash)
      assert_match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}[+-]\d{2}:\d{2}\z/, time)
    end

    it 'should write unknown in a repository without commits' do
      skip 'git is not available' unless git_available?
      git('init', '-q')

      assert(run_install.success?)
      assert_equal("unknown\n", File.read(app_path('version')))
    end
  end

  describe 'install destination' do
    it 'should install into an empty directory' do
      FileUtils.mkdir_p(@appdir)
      assert(run_install.success?)
    end

    it 'should refuse an unrelated directory' do
      make_app_files('note.txt' => 'keep', '.ssh/id_rsa' => 'keep')
      status, out = run_install_with_output
      assert(!status.success?)
      assert_includes(out, 'echo unknown | sudo tee')
      assert_equal('keep', File.read(app_path('note.txt')))
      assert_equal('keep', File.read(app_path('.ssh', 'id_rsa')))
    end

    it 'should refuse a version file in an unknown format' do
      make_app_files('version' => "1.0\n")
      assert(!run_install.success?)
    end

    it 'should refuse another working copy of portfwd' do
      make_app_files('install.sh' => '', 'lib/main.rb' => '', '.ssh/config.rb' => '')
      assert(!run_install.success?)
    end

    it 'should update an install made before the version file' do
      make_app_files('lib/main.rb' => '', '.ssh/config.rb' => '')
      assert(run_install.success?)
      assert(File.exist?(app_path('version')))
    end

    it 'should update an install with portfwd.service made by old versions' do
      make_app_files('portfwd.service' => '', '.ssh/config' => '')
      assert(run_install.success?)
      assert(!File.exist?(app_path('portfwd.service')))
    end

    it 'should resume from leftovers of an interrupted first install' do
      make_app_files('.ssh.new/stale' => '')
      assert(run_install.success?)
      assert(!File.exist?(app_path('.ssh', 'stale')))
      assert(!File.exist?(app_path('.ssh.new')))
    end

    it 'should resume a first install interrupted after a swap' do
      make_app_files('version' => "unknown\n", '.ssh/config' => '')
      assert(run_install.success?)
      assert(File.exist?(app_path('lib', 'main.rb')))
    end

    it 'should refuse a directory with only .ssh.old' do
      make_app_files('.ssh.old/id_rsa' => 'keep')
      assert(!run_install.success?)
      assert_equal('keep', File.read(app_path('.ssh.old', 'id_rsa')))
    end

    it 'should refuse a regular file' do
      File.write(@appdir, '')
      status, out = run_install_with_output
      assert(!status.success?)
      assert_includes(out, 'is not a directory')
    end

    it 'should refuse a symbolic link' do
      target = File.join(@tmpdir, 'target')
      FileUtils.mkdir_p(target)
      File.symlink(target, @appdir)
      assert(!run_install.success?)
      assert(!run_install('ARG_APPDIR' => "#{@appdir}/").success?)
      assert_empty(Dir.children(target))
    end

    it 'should accept a trailing slash' do
      assert(run_install('ARG_APPDIR' => "#{@appdir}/").success?)
      assert(File.exist?(app_path('version')))
    end

    it 'should not write into a version directory' do
      make_app_files('version/keep' => '', 'lib/main.rb' => '', '.ssh/config.rb' => '')
      assert(!run_install.success?)
      assert_equal(['keep'], Dir.children(app_path('version')))
    end
  end
end
