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
        @locale_mutexes = Concurrent::Map.new
        @locale_mutexes_mutex = Mutex.new
      end

      # Returns whether the current locale is initialized.
      def initialized?(locale = I18n.locale)
        if lazy_load?
          initialized_locales[locale]
        else
          super
        end
      end

      # Clean up translations and uninitialize all locales.
      def reload!
        if lazy_load?
          initialized_locales.each_key do |locale|
            initialized_locales[locale] = false
          end
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
        super
      end

      protected

      # Load translations from files that belong to the current locale.
      def init_translations(locale = nil)
        if lazy_load?
          init_lazy_translations(locale)
        else
          translation_loader, file_errors = translation_loader_for(I18n.load_path, deep_dup_hash(translations))
          raise InvalidFilenames.new(file_errors) unless file_errors.empty?

          translations.replace(translation_loader.translations)
          @initialized = true
        end
      end

      def initialized_locales
        @initialized_locales ||= Concurrent::Hash.new(false)
      end

      private

      def lazy_load?
        @lazy_load
      end

      def init_lazy_translations(locale)
        mutex = mutex_for_locale(locale)
        return if initialized_locales[locale]

        if mutex.try_lock
          init_lazy_translations_under_lock(locale, mutex)
        else
          return if translations.key?(locale)

          mutex.synchronize {}
          init_lazy_translations(locale) unless initialized_locales[locale]
        end
      end

      def init_lazy_translations_under_lock(locale, mutex)
        has_version = translations.key?(locale)
        return if initialized_locales[locale]

        begin
          candidate = load_translation_candidate(locale, filenames_for_locale(locale))
          translations[locale] = candidate
          initialized_locales[locale] = true
        rescue StandardError
          raise unless has_version
        ensure
          mutex.unlock
        end
      end

      def mutex_for_locale(locale)
        @locale_mutexes_mutex.synchronize do
          @locale_mutexes.fetch_or_store(locale) { Mutex.new }
        end
      end

      class FilenameIncorrect < StandardError
        def initialize(file, expected_locale, unexpected_locales)
          super "#{file} can only load translations for \"#{expected_locale}\". Found translations for: #{unexpected_locales}."
        end
      end

      class TranslationLoader
        include Base

        attr_reader :translations

        def initialize(translations = {})
          @translations = translations
        end

        def load_translation_file(file)
          load_file(file)
        end

        def store_translations(locale, data, options = EMPTY_HASH)
          locale = locale.to_sym
          data = Utils.deep_symbolize_keys(data) unless options.fetch(:skip_symbolize_keys, false)
          translations[locale] ||= {}
          Utils.deep_merge!(translations[locale], data)
        end
      end

      def translation_loader_for(files, translations = {})
        translation_loader = TranslationLoader.new(translations)
        errors = []

        files.each do |file|
          loaded_translations = load_translation_file(translation_loader, file)
          assert_file_named_correctly!(file, loaded_translations)
        rescue FilenameIncorrect => e
          errors << e
        end

        [translation_loader, errors]
      end

      def load_translation_candidate(locale, files)
        return {} if files.empty?

        translation_loader, file_errors = translation_loader_for(files)

        raise InvalidFilenames.new(file_errors) unless file_errors.empty?

        raise InvalidLocaleData.new(files.first, 'expects it to return a hash, but does not') unless translation_loader.translations.key?(locale)

        translation_loader.translations.fetch(locale)
      end

      def load_translation_file(translation_loader, file)
        translation_loader.load_translation_file(file)
      end

      def deep_dup_hash(value)
        case value
        when Hash
          value.each_with_object({}) do |(key, nested_value), result|
            result[key] = deep_dup_hash(nested_value)
          end
        when Array
          value.map { |item| deep_dup_hash(item) }
        else
          value
        end
      end

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
