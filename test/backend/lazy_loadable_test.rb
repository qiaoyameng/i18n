require 'test_helper'

class I18nBackendLazyLoadableTest < I18n::TestCase
  def setup
    super

    @lazy_mode_backend = I18n::Backend::LazyLoadable.new(lazy_load: true)
    @eager_mode_backend = I18n::Backend::LazyLoadable.new(lazy_load: false)

    I18n.load_path = [File.join(locales_dir, '/en.yml'), File.join(locales_dir, '/en.yaml'), File.join(locales_dir,  '/fr.yml')]
  end

  test "lazy mode: only loads translations for current locale" do
    with_lazy_mode do
      @backend.reload!

      assert_nil translations

      I18n.with_locale(:en) { I18n.t("foo.bar") }
      assert_equal({ en: { foo: { bar: "baz" }}}, translations)
    end
  end

  test "lazy mode: merges translations for current locale with translations already existing in memory" do
    with_lazy_mode do
      @backend.reload!

      I18n.with_locale(:en) { I18n.t("foo.bar") }
      assert_equal({ en: { foo: { bar: "baz" }}}, translations)

      I18n.with_locale(:fr) { I18n.t("animal.dog") }
      assert_equal({ en: { foo: { bar: "baz" } }, fr: { animal: { dog: "chien" } } }, translations)
    end
  end

  test "lazy mode: #initialized? responds based on whether current locale is initialized" do
    with_lazy_mode do
      @backend.reload!

      I18n.with_locale(:en) do
        refute_predicate @backend, :initialized?
        I18n.t("foo.bar")
        assert_predicate @backend, :initialized?
      end

      I18n.with_locale(:fr) do
        refute_predicate @backend, :initialized?
      end
    end
  end

  test "lazy mode: reload! uninitializes all locales" do
    with_lazy_mode do
      I18n.with_locale(:en) { I18n.t("foo.bar") }
      I18n.with_locale(:fr) { I18n.t("animal.dog") }

      @backend.reload!

      I18n.with_locale(:en) do
        refute_predicate @backend, :initialized?
      end

      I18n.with_locale(:fr) do
        refute_predicate @backend, :initialized?
      end
    end
  end

  test "lazy mode: eager_load! raises UnsupportedMethod exception" do
    with_lazy_mode do
      exception = assert_raises(I18n::UnsupportedMethod) { @backend.eager_load! }
      expected_msg = "I18n::Backend::LazyLoadable does not support the #eager_load! method. Cannot eager load translations because backend was configured with lazy_load: true." 
      assert_equal expected_msg, exception.message
    end
  end

  test "lazy mode: loads translations from files that start with current locale identifier" do
    with_lazy_mode do
      file_contents = { en: { alice: "bob" } }.to_yaml

      invalid_files = [
        { filename: ['translation', '.yml'] },                # No locale identifier
        { filename: ['translation', '.unsupported'] },        # No locale identifier and unsupported extension
      ]

      invalid_files.each do |file|
        with_translation_file_in_load_path(file[:filename], file[:dir], file_contents) do
          I18n.with_locale(:en) { I18n.t("foo.bar") }
          assert_equal({ en: { foo: { bar: "baz" }}}, translations)
        end
      end

      valid_files = [
        { filename: ['en_translation', '.yml'] },         # Contains locale identifier with correct demarcation, and supported extension
        { filename: ['en_', '.yml'] },                    # Path component matches locale identifier exactly
      ]

      valid_files.each do |file|
        with_translation_file_in_load_path(file[:filename], file[:dir], file_contents) do
          I18n.with_locale(:en) { I18n.t("foo.bar") }
          assert_equal({ en: { foo: { bar: "baz" }, alice: "bob" }}, translations)
        end
      end
    end
  end

  test "lazy mode: files with unsupported extensions raise UnknownFileType error" do
    with_lazy_mode do
      file_contents = { en: { alice: "bob" } }.to_yaml
      filename =  ['en_translation', '.unsupported']     # Correct locale identifier, but unsupported extension

      with_translation_file_in_load_path(filename, nil, file_contents) do
        assert_raises(I18n::UnknownFileType) { I18n.t("foo.bar") }
      end
    end
  end

  test "lazy mode: #available_locales returns all locales available from load path irrespective of current locale" do
    with_lazy_mode do
      I18n.with_locale(:en) { assert_equal [:en, :fr], @backend.available_locales }
      I18n.with_locale(:fr) { assert_equal [:en, :fr], @backend.available_locales }
    end
  end

  test "lazy mode: raises error if translations loaded don't correspond to locale extracted from filename" do
    filename = ["en_", ".yml"]
    file_contents = { fr: { dog: "chien" } }.to_yaml

    with_lazy_mode do
      with_translation_file_in_load_path(filename, nil, file_contents) do |file_path|
        exception = assert_raises(I18n::InvalidFilenames) { I18n.t("foo.bar") }

        expected_message = /#{Regexp.escape(file_path)} can only load translations for "en"\. Found translations for: \[\:fr\]/
        assert_match expected_message, exception.message
      end
    end
  end

  test "lazy mode: raises error if translations for more than one locale are loaded from a single file" do
    filename = ["en_", ".yml"]
    file_contents = { en: { alice: "bob" },  fr: { dog: "chien" }, de: { cat: 'katze' } }.to_yaml

    with_lazy_mode do
      with_translation_file_in_load_path(filename, nil, file_contents) do |file_path|
        exception = assert_raises(I18n::InvalidFilenames) { I18n.t("foo.bar") }

        expected_message = /#{Regexp.escape(file_path)} can only load translations for "en"\. Found translations for: \[\:fr\, \:de\]/
        assert_match expected_message, exception.message
      end
    end
  end

  test "lazy mode: #lookup lazy loads translations for supplied locale" do
    with_lazy_mode do
      @backend.reload!
      assert_nil translations

      I18n.with_locale(:en) do
        assert_equal "chien", @backend.lookup(:fr, "animal.dog")
      end

      assert_equal({ fr: { animal: { dog: "chien" } } }, translations)
    end
  end

  test "lazy mode: a failed first load publishes no keys and can be retried" do
    with_lazy_mode do
      with_locale_files("en_first.yml" => { en: { good: "key" } }.to_yaml,
                        "en_second.yml" => { de: { bad: "key" } }.to_yaml) do |files|
        exception = assert_raises(I18n::InvalidFilenames) { I18n.with_locale(:en) { I18n.t("good") } }

        assert_match(/#{Regexp.escape(files["en_second.yml"])}/, exception.message)
        assert_nil translations

        rewrite_locale_file(files["en_second.yml"], { en: { bad: "fixed" } }.to_yaml)

        assert_equal "key", I18n.with_locale(:en) { I18n.t("good") }
        assert_equal "fixed", I18n.with_locale(:en) { I18n.t("bad") }
      end
    end
  end

  test "lazy mode: a YAML parse error in a later file leaves no partial dictionary and retries" do
    with_lazy_mode do
      with_locale_files("en_first.yml" => { en: { alpha: "one" } }.to_yaml,
                        "en_second.yml" => "en:\n  beta: {oops\n") do |files|
        exception = assert_raises(I18n::InvalidLocaleData) { I18n.with_locale(:en) { I18n.t("alpha") } }

        assert_equal files["en_second.yml"], exception.filename
        assert_nil translations

        rewrite_locale_file(files["en_second.yml"], { en: { beta: "two" } }.to_yaml)

        assert_equal "one", I18n.with_locale(:en) { I18n.t("alpha") }
        assert_equal "two", I18n.with_locale(:en) { I18n.t("beta") }
      end
    end
  end

  test "lazy mode: a failed reload keeps serving the previously loaded version" do
    with_lazy_mode do
      with_locale_files("en_first.yml" => { en: { alpha: "one" } }.to_yaml,
                        "en_second.yml" => { en: { beta: "two" } }.to_yaml) do |files|
        assert_equal "one", I18n.with_locale(:en) { I18n.t("alpha") }
        assert_equal "two", I18n.with_locale(:en) { I18n.t("beta") }

        rewrite_locale_file(files["en_second.yml"], "en:\n  beta: {oops\n")
        @backend.reload!

        exception = assert_raises(I18n::InvalidLocaleData) { I18n.with_locale(:en) { I18n.t("alpha") } }
        assert_equal files["en_second.yml"], exception.filename

        assert_equal({ alpha: "one", beta: "two" }, translations[:en])

        rewrite_locale_file(files["en_second.yml"], { en: { beta: "three" } }.to_yaml)
        assert_equal "three", I18n.with_locale(:en) { I18n.t("beta") }
      end
    end
  end

  test "lazy mode: locales load and fail independently" do
    with_lazy_mode do
      with_locale_files("en_first.yml" => { en: { good: "key" } }.to_yaml,
                        "en_second.yml" => { de: { bad: "key" } }.to_yaml,
                        "fr.yml" => { fr: { animal: { dog: "chien" } } }.to_yaml) do
        assert_equal "chien", I18n.with_locale(:fr) { I18n.t("animal.dog") }
        assert_raises(I18n::InvalidFilenames) { I18n.with_locale(:en) { I18n.t("good") } }

        assert(translations[:en].nil? || translations[:en].empty?)
        assert_equal "chien", I18n.with_locale(:fr) { I18n.t("animal.dog") }
      end
    end
  end

  test "lazy mode: concurrent readers during a failed reload only see the complete old version" do
    @backend = I18n.backend = I18n::Backend::LazyLoadable.new(lazy_load: true)
    with_locale_files("en_first.yml" => { en: { alpha: "old_a", beta: "old_b" } }.to_yaml,
                      "en_second.yml" => { en: { gamma: "old_c" } }.to_yaml) do |files|
      backend = @backend
      I18n.enforce_available_locales = false

      assert_equal "old_a", I18n.with_locale(:en) { I18n.t("alpha") }

      rewrite_locale_file(files["en_second.yml"], "en:\n  gamma: {oops\n")
      backend.reload!

      reader_count = 8
      load_started = Queue.new
      release_load = Queue.new
      seen = {}
      mutex = Mutex.new

      # Park the leader once it has acquired the load but before it parses any
      # file. Follower readers started afterwards block on the locale mutex.
      # The leader is released while the followers are still blocked, so it
      # parses the files and fails; the followers then wake up and must fall
      # back to the complete old version rather than raise or see partial data.
      backend.singleton_class.send(:define_method, :around_locale_load) do |&block|
        load_started << :started
        release_load.pop
        block.call
      end

      leader_error = nil
      leader = Thread.new do
        begin
          I18n.with_locale(:en) { I18n.t("alpha") }
        rescue I18n::InvalidLocaleData => e
          leader_error = e
        end
      end

      load_started.pop

      followers = reader_count.times.map do
        Thread.new do
          values = I18n.with_locale(:en) { [:alpha, :beta, :gamma].map { |key| I18n.t(key) } }
          mutex.synchronize { seen[values] = true }
        end
      end

      # Let followers reach the locale mutex while the leader stays parked.
      Thread.pass until followers_blocked?(backend, :en, reader_count)

      release_load << :continue
      leader.join
      followers.each(&:join)

      assert_instance_of I18n::InvalidLocaleData, leader_error
      assert_equal files["en_second.yml"], leader_error.filename
      assert_equal [%w[old_a old_b old_c]], seen.keys
      assert_equal({ alpha: "old_a", beta: "old_b", gamma: "old_c" }, translations[:en])
    end
  end

  test "eager mode: load all translations, irrespective of locale" do
    with_eager_mode do
      @backend.reload!

      assert_nil translations

      I18n.with_locale(:en) { I18n.t("foo.bar") }
      assert_equal({ en: { foo: { bar: "baz" } }, fr: { animal: { dog: "chien" } } }, translations)
    end
  end

  test "eager mode: raises error if locales loaded cannot be extracted from load path names" do
    with_eager_mode do
      @backend.reload!

      contents = { de: { cat: 'katze' } }.to_yaml

      with_translation_file_in_load_path(['fr_translation', '.yml'], nil, contents) do |file_path|
        exception = assert_raises(I18n::InvalidFilenames) { I18n.t("foo.bar") }

        expected_message = /#{Regexp.escape(file_path)} can only load translations for "fr"\. Found translations for: \[\:de\]/
        assert_match expected_message, exception.message
      end
    end
  end

  private

  def with_lazy_mode
    @backend = I18n.backend = @lazy_mode_backend

    yield
  end

  def with_eager_mode
    @backend = I18n.backend = @eager_mode_backend

    yield
  end


  def with_translation_file_in_load_path(name, tmpdir, file_contents)
    @backend.reload!

    path_to_dir = FileUtils.mkdir_p(File.join(Dir.tmpdir, tmpdir)).first if tmpdir
    locale_file = Tempfile.new(name, path_to_dir)

    locale_file.write(file_contents)
    locale_file.rewind

    I18n.load_path << locale_file.path

    yield(locale_file.path)

    I18n.load_path.delete(locale_file.path)
  end

  # Creates real files (stable names are required because the lazy backend
  # derives the locale from the filename) and yields a mapping of name -> path.
  def with_locale_files(files)
    require 'tmpdir'
    Dir.mktmpdir do |dir|
      @backend.reload!

      paths = files.each_with_object({}) do |(name, contents), result|
        path = File.join(dir, name)
        File.write(path, contents)
        result[name] = path
      end

      I18n.load_path = paths.values

      yield(paths)
    end
  end

  def rewrite_locale_file(path, contents)
    File.write(path, contents)
  end

  # Whether +count+ follower threads are blocked waiting for the locale load.
  def followers_blocked?(backend, locale, count)
    load = backend.send(:locale_load, locale)
    load.mutex.synchronize { load.waiters >= count }
  end
end
