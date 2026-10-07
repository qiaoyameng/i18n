# frozen_string_literal: true

module I18n
  module Backend
    # Backend that lazy loads translations based on the current locale. This
    # implementation avoids loading all translations up front. Instead, it only
    # loads the translations that belong to the current locale. This offers a
    # performance incentive in local development and test environments for
    # applications with many translations for many different locales. It's
    # particularly useful when the application only refers to a single locales'
    # translations at a time (ex. A Rails workload).  The implementation
    # identifies which translation files from the load path belong to the
    # current locale by pattern matching against their path name.
    #
    # Specifically, a translation file is considered to belong to a locale if:
    # a) the filename is in the I18n load path
    # b) the filename ends in a supported extension (ie. .yml, .json, .po, .rb)
    # c) the filename starts with the locale identifier
    # d) the locale identifier and optional proceeding text is separated by an underscore, ie. "_".
    #
    # Examples:
    # Valid files that will be selected by this backend:
    #
    # "files/locales/en_translation.yml" (Selected for locale "en")
    # "files/locales/fr.po"  (Selected for locale "fr")
    #
    # Invalid files that won't be selected by this backend:
    #
    # "files/locales/translation-file"
    # "files/locales/en-translation.unsupported"
    # "files/locales/french/translation.yml"
    # "files/locales/fr/translation.yml"
    #
    # The implementation uses this assumption to defer the loading of
    # translation files until the current locale actually requires them.
    #
    # The backend has two working modes: lazy_load and eager_load.
    #
    # Note: This backend should only be enabled in test environments!
    # When the mode is set to false, the backend behaves exactly like the
    # Simple backend, with an additional check that the paths being loaded
    # abide by the format. If paths can't be matched to the format, an error is raised.
    #
    # You can configure lazy loaded backends through the initializer or backends
    # accessor:
    #
    #   # In test environments
    #
    #   I18n.backend = I18n::Backend::LazyLoadable.new(lazy_load: true)
    #
    #   # In other environments, such as production and CI
    #
    #   I18n.backend = I18n::Backend::LazyLoadable.new(lazy_load: false) # default
    #
    class LocaleExtractor
      class << self
        def locale_from_path(path)
          name = File.basename(path, ".*")
          locale = name.split("_").first
          locale.to_sym unless locale.nil?
        end
      end
    end

    class LazyLoadable < Simple
      def initialize(lazy_load: false)
        @lazy_load = lazy_load
      end

      # Returns whether the current locale is initialized.
      def initialized?
        if lazy_load?
          initialized_locales.fetch(I18n.locale, false)
        else
          super
        end
      end

      # Clean up translations and uninitialize all locales.
      def reload!
        if lazy_load?
          @initialized_locales = nil
        else
          super
        end
      end

      # Eager loading is not supported in the lazy context.
      def eager_load!
        if lazy_load?
          raise UnsupportedMethod.new(__method__, self.class, "Cannot eager load translations because backend was configured with lazy_load: true.")
        else
          super
        end
      end

      # Parse the load path and extract all locales.
      def available_locales
        if lazy_load?
          I18n.load_path.map { |path| LocaleExtractor.locale_from_path(path) }.uniq
        else
          super
        end
      end

      def lookup(locale, key, scope = [], options = EMPTY_HASH)
        if lazy_load?
          I18n.with_locale(locale) do
            init_locale_translations(locale) unless initialized?
            super
          end
        else
          super
        end
      end

      protected


      # Load translations from files that belong to the current locale.
      def init_translations
        return if lazy_load?

        @initialized = true
        file_errors = load_translations_and_collect_file_errors(I18n.load_path)

        raise InvalidFilenames.new(file_errors) unless file_errors.empty?
      end

      def initialized_locales
        @initialized_locales ||= {}
      end

      private

      def lazy_load?
        @lazy_load
      end

      # Per-locale synchronization primitive that coalesces concurrent loads.
      # The leader holds +mutex+ for the entire duration of its load, so
      # followers simply block on mutex acquisition. +attempt+ is bumped on
      # every finished load; a follower that observed an in-progress attempt
      # records that attempt's number and neither waits for nor leads that
      # same attempt again, even if it performs several lookups in a row.
      LocaleLoad = Struct.new(:mutex, :condition, :leader, :attempt, :waiters) do
        # Claims participation in a load. Returns a pair [role, attempt]:
        #   * [:leader, n]  - the caller owns a new load attempt and must run it
        #   * [:follower, n]- an attempt was running; the caller waited it out
        #   * [:skip, n]    - the caller already witnessed attempt +n+, so it
        #                      should just read the stored translations
        def claim(thread, seen)
          mutex.synchronize do
            if leader
              self.waiters += 1
              condition.wait(mutex) while leader
              self.waiters -= 1
              [:follower, attempt]
            elsif seen == attempt
              [:skip, attempt]
            else
              self.leader = thread
              [:leader, attempt]
            end
          end
        end

        def complete!
          mutex.synchronize do
            self.leader = nil
            self.attempt += 1
            condition.broadcast
          end
        end
      end

      # Load attempt number most recently witnessed by this thread for a
      # locale, so concurrent follow-up lookups do not wait twice.
      def seen_attempt(load)
        (@seen_attempts ||= {})[load]
      end

      def remember_attempt!(load, attempt)
        (@seen_attempts ||= {})[load] = attempt
      end

      # Atomically loads every translation file that belongs to the given
      # locale. Files are first parsed and validated into an isolated hash.
      # Only when all of them succeed is the new data published for the
      # locale, replacing the previously visible version in a single swap.
      # This guarantees that readers never observe a partially loaded
      # dictionary or a mix of old and new files.
      #
      # Concurrent lookups for the same locale coalesce: the first lookup
      # leads the load while the others wait for it to finish. Followers never
      # raise: if the leader fails and an old version exists they are served
      # that version by the subsequent lookup. The leader always reports the
      # real error (with file information). On failure nothing is published
      # and the locale stays uninitialized, so a subsequent lookup retries.
      def init_locale_translations(locale)
        return if initialized_locales[locale]

        load = locale_load(locale)
        role, attempt = load.claim(Thread.current, seen_attempt(load))
        remember_attempt!(load, attempt)
        return if role == :follower || role == :skip

        begin
          around_locale_load { load_locale_translations(locale) }
        ensure
          load.complete!
        end
      end

      # Extension point wrapping the actual parsing of a locale's files.
      # Override to observe an in-progress load; the default implementation
      # simply yields.
      def around_locale_load
        yield
      end

      def load_locale_translations(locale)
        candidate = {}
        file_errors = []

        filenames_for_locale(locale).each do |file|
          data, keys_symbolized = parse_file(file)
          assert_file_named_correctly!(file, data)
          merge_into(candidate, data, keys_symbolized)
        rescue FilenameIncorrect => e
          file_errors << e
        end

        raise InvalidFilenames.new(file_errors) unless file_errors.empty?

        # Loading failed (parse error or unsupported file type) before we get
        # here: nothing has been published, so any previously visible version
        # stays in place and the locale remains uninitialized for a retry.
        publish_locale_translations(locale, candidate)
        initialized_locales[locale] = true
      end

      # Merges parsed file data into the isolated candidate hash without
      # touching the live translations store.
      def merge_into(candidate, data, keys_symbolized)
        data = Utils.deep_symbolize_keys(data) unless keys_symbolized
        data.each { |file_locale, d| Utils.deep_merge!(candidate[file_locale] ||= {}, d || {}) }
      end

      # Replaces the locale's visible translations with the freshly parsed
      # data in a single assignment. Using a brand new subtree means readers
      # always observe either the complete old version or the complete new
      # one, never an intermediate state.
      def publish_locale_translations(locale, candidate)
        new_data = candidate[locale] || {}
        translations[locale] = Concurrent::Hash.new.merge!(new_data)
      end

      def locale_load(locale)
        @locale_loads_mutex ||= Mutex.new
        @locale_loads_mutex.synchronize do
          @locale_loads ||= {}
          @locale_loads[locale] ||= LocaleLoad.new(Mutex.new, ConditionVariable.new, nil, 0, 0)
        end
      end

      class FilenameIncorrect < StandardError
        def initialize(file, expected_locale, unexpected_locales)
          super "#{file} can only load translations for \"#{expected_locale}\". Found translations for: #{unexpected_locales}."
        end
      end

      # Loads each file supplied and asserts that the file only loads
      # translations as expected by the name. The method returns a list of
      # errors corresponding to offending files.
      def load_translations_and_collect_file_errors(files)
        errors = []

        load_translations(files) do |file, loaded_translations|
          assert_file_named_correctly!(file, loaded_translations)
        rescue FilenameIncorrect => e
          errors << e
        end

        errors
      end

      # Select all files from I18n load path that belong to current locale.
      # These files must start with the locale identifier (ie. "en", "pt-BR"),
      # followed by an "_" demarcation to separate proceeding text.
      def filenames_for_locale(locale)
        I18n.load_path.flatten.select do |path|
          LocaleExtractor.locale_from_path(path) == locale
        end
      end

      # Checks if a filename is named in correspondence to the translations it loaded.
      # The locale extracted from the path must be the single locale loaded in the translations.
      def assert_file_named_correctly!(file, translations)
        loaded_locales = translations.keys.map(&:to_sym)
        expected_locale = LocaleExtractor.locale_from_path(file)
        unexpected_locales = loaded_locales.reject { |locale| locale == expected_locale }

        raise FilenameIncorrect.new(file, expected_locale, unexpected_locales) unless unexpected_locales.empty?
      end
    end
  end
end
