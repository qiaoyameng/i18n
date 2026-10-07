require 'test_helper'
require 'tmpdir'

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

  test "lazy mode: a parse error in a later file does not publish partial translations" do
    with_lazy_mode do
      with_locale_files(
        "en_one.yml" => "en:\n  first: value\n",
        "en_two.yml" => "en:\n foo: foo\n    bar:\n"
      ) do |files|
        I18n.with_locale(:en) do
          exception = assert_raises(I18n::InvalidLocaleData) do
            @backend.lookup(:en, :first)
          end

          assert_equal files[1], exception.filename
          assert_empty translations

          File.write(files[1], "en:\n  second: value\n")

          assert_equal "value", @backend.lookup(:en, :first)
          assert_equal "value", @backend.lookup(:en, :second)
        end
      end
    end
  end

  test "lazy mode: a filename mismatch does not publish translations from an earlier file" do
    with_lazy_mode do
      with_locale_files(
        "en_one.yml" => "en:\n  first: value\n",
        "en_two.yml" => "fr:\n  dog: chien\n"
      ) do |files|
        I18n.with_locale(:en) do
          exception = assert_raises(I18n::InvalidFilenames) do
            @backend.lookup(:en, :first)
          end

          assert_includes exception.message, files[1]
          assert_empty translations
        end
      end
    end
  end

  test "lazy mode: a failed reload keeps serving the previous version" do
    with_lazy_mode do
      with_locale_files("en_one.yml" => "en:\n  old: value\n") do |files, dir|
        I18n.with_locale(:en) do
          assert_equal "value", @backend.lookup(:en, :old)

          invalid_file = File.join(dir, "en_two.yml")
          File.write(invalid_file, "en:\n foo: foo\n    bar:\n")
          I18n.load_path << invalid_file
          @backend.reload!

          assert_equal "value", @backend.lookup(:en, :old)
          refute_predicate @backend, :initialized?

          File.write(files.first, "en:\n  first: value\n")
          File.write(invalid_file, "en:\n  new: value\n")

          assert_nil @backend.lookup(:en, :old)
          assert_equal "value", @backend.lookup(:en, :new)
        end
      end
    end
  end

  test "lazy mode: locales load independently when one locale is invalid" do
    with_lazy_mode do
      with_locale_files(
        "en_one.yml" => "en:\n  first: value\n",
        "en_two.yml" => "en:\n foo: foo\n    bar:\n",
        "fr_one.yml" => "fr:\n  dog: chien\n"
      ) do |files|
        I18n.with_locale(:en) do
          assert_raises(I18n::InvalidLocaleData) do
            @backend.lookup(:en, :first)
          end
        end

        assert_equal "chien", @backend.lookup(:fr, :dog)
        assert_equal [:fr], translations.keys

        File.write(files[1], "en:\n  second: value\n")

        assert_equal "value", @backend.lookup(:en, :first)
        assert_equal "value", @backend.lookup(:en, :second)
      end
    end
  end

  test "lazy mode: reads during a reload see only the complete old or new version" do
    with_lazy_mode do
      with_locale_files("en_one.yml" => "en:\n  old: value\n") do |_files, dir|
        first_file = File.join(dir, "en_one.yml")
        second_file = File.join(dir, "en_two.yml")

        I18n.with_locale(:en) do
          assert_equal "value", @backend.lookup(:en, :old)
        end

        File.write(first_file, "en:\n  first: value\n")
        File.write(second_file, "en:\n  second: value\n")
        I18n.load_path << second_file
        @backend.reload!

        parsed = Queue.new
        release = Queue.new
        instrumenter = Module.new do
          define_method(:load_translation_file) do |translation_loader, file|
            result = super(translation_loader, file)
            if file == first_file
              parsed << true
              release.pop
            end
            result
          end
        end
        @backend.singleton_class.prepend(instrumenter)

        reloader = Thread.new do
          I18n.with_locale(:en) do
            @backend.lookup(:en, :first)
          end
        end

        parsed.pop

        begin
          I18n.with_locale(:en) do
            assert_equal "value", @backend.lookup(:en, :old)
            assert_nil @backend.lookup(:en, :first)
            assert_nil @backend.lookup(:en, :second)
          end
        ensure
          release << true
        end

        assert_equal "value", reloader.value
        assert_nil @backend.lookup(:en, :old)
        assert_equal "value", @backend.lookup(:en, :first)
        assert_equal "value", @backend.lookup(:en, :second)
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

  def with_locale_files(files)
    Dir.mktmpdir do |dir|
      paths = files.map do |name, contents|
        File.join(dir, name).tap { |path| File.write(path, contents) }
      end

      I18n.load_path = []
      @backend.reload!
      I18n.load_path.concat(paths)

      yield(paths, dir)
    end
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
end
