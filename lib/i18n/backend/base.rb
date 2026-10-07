# frozen_string_literal: true

require 'yaml'
require 'json'

module I18n
  module Backend
    module Base
      include I18n::Backend::Transliterator

      # Accepts a list of paths to translation files. Loads translations from
      # plain Ruby (*.rb), YAML files (*.yml), or JSON files (*.json). See #load_rb, #load_yml, and #load_json
      # for details.
      def load_translations(*filenames)
        filenames = I18n.load_path if filenames.empty?
        filenames.flatten.each do |filename|
          loaded_translations = load_file(filename)
          yield filename, loaded_translations if block_given?
        end
      end

      # This method receives a locale, a data hash and options for storing translations.
      # Should be implemented
      def store_translations(locale, data, options = EMPTY_HASH)
        raise NotImplementedError
      end

      def translate(locale, key, options = EMPTY_HASH)
        raise I18n::ArgumentError if (key.is_a?(String) || key.is_a?(Symbol)) && key.empty?
        raise InvalidLocale.new(locale) unless locale
        return nil if key.nil? && !options.key?(:default)

        tracer = I18n::Trace.current
        if tracer
          tracer.wrap(:lookup, lookup_trace_attributes(locale, key, options)) do
            translate_resolution(locale, key, options)
          end
        else
          translate_resolution(locale, key, options)
        end
      end

      def lookup_trace_attributes(locale, key, options)
        {
          backend: I18n::Trace.backend_name(self),
          locale: locale,
          original_locale: options[:fallback_original_locale],
          key: key,
          scope: options[:scope]
        }
      end

      # Calls #pluralize inside a :plural trace entry. The selected branch is
      # obtained from the (possibly overridden) pluralize implementation via
      # #trace_plural_key without pluralizing a second time.
      def trace_pluralize(locale, entry, key, count)
        return entry unless count

        tracer = I18n::Trace.current
        return pluralize(locale, entry, count) unless tracer

        plural_node = nil
        result = tracer.wrap(:plural, locale: locale, key: key, count: count) do
          plural_node = tracer.last_entry
          pluralize(locale, entry, count)
        end
        selected = trace_plural_key(entry, count, result)
        plural_node.plural_key = selected if selected && plural_node
        result
      end

      # Determines which pluralization subkey the pluralize implementation
      # selected, purely by inspecting the data it already used. Returns nil
      # when it cannot be inferred.
      def trace_plural_key(entry, count, result)
        return nil unless entry.is_a?(Hash)

        matching = entry.find { |_key, value| value.equal?(result) || value == result }
        matching&.first
      end

      private def translate_resolution(locale, key, options)
        entry = lookup(locale, key, options[:scope], options) unless key.nil?

        if entry.nil? && options.key?(:default)
          entry = default(locale, key, options[:default], options)
        else
          entry = resolve_entry(locale, key, entry, options)
        end

        count = options[:count]

        if entry.nil? && (subtrees? || !count)
          if (options.key?(:default) && !options[:default].nil?) || !options.key?(:default)
            throw(:exception, I18n::MissingTranslation.new(locale, key, options))
          end
        end

        entry = entry.dup if entry.is_a?(String)
        entry = trace_pluralize(locale, entry, key, count)

        if entry.nil? && !subtrees?
          throw(:exception, I18n::MissingTranslation.new(locale, key, options))
        end

        deep_interpolation = options[:deep_interpolation]
        skip_interpolation = options[:skip_interpolation]
        values = Utils.except(options, *RESERVED_KEYS) unless options.empty?
        if !skip_interpolation && values && !values.empty?
          if I18n::Trace.current
            # The resolved string embeds caller supplied values; make sure no
            # open entry (lookup, fallback, backend, root) retains it.
            I18n::Trace.current.suppress_value_capture!
            entry = I18n::Trace.current.wrap(:interpolate, { locale: locale, key: key, capture: false }) do
              if deep_interpolation
                deep_interpolate(locale, entry, values)
              else
                interpolate(locale, entry, values)
              end
            end
          else
            entry = if deep_interpolation
              deep_interpolate(locale, entry, values)
            else
              interpolate(locale, entry, values)
            end
          end
        elsif entry.is_a?(String) && entry =~ I18n.reserved_keys_pattern
          raise ReservedInterpolationKey.new($1.to_sym, entry)
        end
        entry
      end

      def exists?(locale, key, options = EMPTY_HASH)
        lookup(locale, key, options[:scope]) != nil
      end

      # Acts the same as +strftime+, but uses a localized version of the
      # format string. Takes a key from the date/time formats translations as
      # a format argument (<em>e.g.</em>, <tt>:short</tt> in <tt>:'date.formats'</tt>).
      def localize(locale, object, format = :default, options = EMPTY_HASH)
        if object.nil? && options.include?(:default)
          return options[:default]
        end
        raise ArgumentError, "Object must be a Date, DateTime or Time object. #{object.inspect} given." unless object.respond_to?(:strftime)

        if Symbol === format
          key  = format
          type = object.respond_to?(:sec) ? 'time' : 'date'
          options = options.merge(:raise => true, :object => object, :locale => locale)
          format  = I18n.t(:"#{type}.formats.#{key}", **options)
        end

        format = translate_localization_format(locale, object, format, options)
        object.strftime(format)
      end

      # Returns an array of locales for which translations are available
      # ignoring the reserved translation meta data key :i18n.
      def available_locales
        raise NotImplementedError
      end

      def reload!
        eager_load! if eager_loaded?
      end

      def eager_load!
        @eager_loaded = true
      end

      protected

        def eager_loaded?
          @eager_loaded ||= false
        end

        # The method which actually looks up for the translation in the store.
        def lookup(locale, key, scope = [], options = EMPTY_HASH)
          raise NotImplementedError
        end

        def subtrees?
          true
        end

        # Evaluates defaults.
        # If given subject is an Array, it walks the array and returns the
        # first translation that can be resolved. Otherwise it tries to resolve
        # the translation directly.
        def default(locale, object, subject, options = EMPTY_HASH)
          if options.size == 1 && options.has_key?(:default)
            options = {}
          else
            options = Utils.except(options, :default)
          end

          case subject
          when Array
            subject.each do |item|
              result = trace_default(locale, object, item, options) { resolve(locale, object, item, options) }
              return result unless result.nil?
            end and nil
          else
            trace_default(locale, object, subject, options) { resolve(locale, object, subject, options) }
          end
        end

        def trace_default(locale, object, item, options, &resolution)
          tracer = I18n::Trace.current
          return yield unless tracer

          attributes = {
            locale: locale,
            key: object,
            scope: options[:scope],
            default_type: I18n::Trace.default_type(item)
          }
          unless item.is_a?(Proc)
            attributes[:default] = item
          end
          if item.is_a?(Proc)
            # The :default entry is the parent; the actual Proc evaluation is
            # recorded as a nested :proc entry by #resolve.
            tracer.wrap(:default, attributes.merge(capture: false), &resolution)
          else
            tracer.wrap(:default, attributes, &resolution)
          end
        end

        # Resolves a translation.
        # If the given subject is a Symbol, it will be translated with the
        # given options. If it is a Proc then it will be evaluated. All other
        # subjects will be returned directly.
        def resolve(locale, object, subject, options = EMPTY_HASH)
          return subject if options[:resolve] == false
          result = catch(:exception) do
            case subject
            when Symbol
              trace_alias(locale, subject, options) do
                I18n.translate(
                  subject,
                  **options.merge(
                    :locale => locale,
                    :throw => true,
                    :skip_interpolation => true
                  )
                )
              end
            when Proc
              date_or_time = options.delete(:object) || object
              tracer = I18n::Trace.current
              called = if tracer
                tracer.wrap(:proc, locale: locale, key: object, capture: false) do
                  subject.call(date_or_time, **options)
                end
              else
                subject.call(date_or_time, **options)
              end
              resolve(locale, object, called)
            else
              subject
            end
          end
          result unless result.is_a?(MissingTranslation)
        end
        alias_method :resolve_entry, :resolve

        def trace_alias(locale, subject, options)
          tracer = I18n::Trace.current
          return yield unless tracer

          tracer.wrap(
            :alias,
            locale: locale,
            key: subject,
            alias_key: subject,
            scope: options[:scope]
          ) { yield }
        end

        # Picks a translation from a pluralized mnemonic subkey according to English
        # pluralization rules :
        # - It will pick the :one subkey if count is equal to 1.
        # - It will pick the :other subkey otherwise.
        # - It will pick the :zero subkey in the special case where count is
        #   equal to 0 and there is a :zero subkey present. This behaviour is
        #   not standard with regards to the CLDR pluralization rules.
        # Other backends can implement more flexible or complex pluralization rules.
        def pluralize(locale, entry, count)
          entry = entry.reject { |k, _v| k == :attributes } if entry.is_a?(Hash)
          return entry unless entry.is_a?(Hash) && count

          key = pluralization_key(entry, count)
          raise InvalidPluralizationData.new(entry, count, key) unless entry.has_key?(key)
          entry[key]
        end

        # Interpolates values into a given subject.
        #
        #   if the given subject is a string then:
        #   method interpolates "file %{file} opened by %%{user}", :file => 'test.txt', :user => 'Mr. X'
        #   # => "file test.txt opened by %{user}"
        #
        #   if the given subject is an array then:
        #   each element of the array is recursively interpolated (until it finds a string)
        #   method interpolates ["yes, %{user}", ["maybe no, %{user}", "no, %{user}"]], :user => "bartuz"
        #   # => ["yes, bartuz", ["maybe no, bartuz", "no, bartuz"]]
        def interpolate(locale, subject, values = EMPTY_HASH)
          return subject if values.empty?

          case subject
          when ::String then I18n.interpolate(subject, values)
          when ::Array then subject.map { |element| interpolate(locale, element, values) }
          else
            subject
          end
        end

        # Deep interpolation
        #
        #   deep_interpolate { people: { ann: "Ann is %{ann}", john: "John is %{john}" } },
        #                    ann: 'good', john: 'big'
        #   #=> { people: { ann: "Ann is good", john: "John is big" } }
        def deep_interpolate(locale, data, values = EMPTY_HASH)
          return data if values.empty?

          case data
          when ::String
            I18n.interpolate(data, values)
          when ::Hash
            data.each_with_object({}) do |(k, v), result|
              result[k] = deep_interpolate(locale, v, values)
            end
          when ::Array
            data.map do |v|
              deep_interpolate(locale, v, values)
            end
          else
            data
          end
        end

        # Loads a single translations file by delegating to #load_rb or
        # #load_yml depending on the file extension and directly merges the
        # data to the existing translations. Raises I18n::UnknownFileType
        # for all other file extensions.
        def load_file(filename)
          type = File.extname(filename).tr('.', '').downcase
          raise UnknownFileType.new(type, filename) unless respond_to?(:"load_#{type}", true)
          data, keys_symbolized = send(:"load_#{type}", filename)
          unless data.is_a?(Hash)
            raise InvalidLocaleData.new(filename, 'expects it to return a hash, but does not')
          end
          data.each { |locale, d| store_translations(locale, d || {}, skip_symbolize_keys: keys_symbolized) }

          data
        end

        # Loads a plain Ruby translations file. eval'ing the file must yield
        # a Hash containing translation data with locales as toplevel keys.
        def load_rb(filename)
          translations = eval(IO.read(filename), binding, filename.to_s)
          [translations, false]
        end

        # Loads a YAML translations file. The data must have locales as
        # toplevel keys.
        def load_yml(filename)
          begin
            if YAML.respond_to?(:unsafe_load_file) # Psych 4.0 way
              [YAML.unsafe_load_file(filename, symbolize_names: true, freeze: true), true]
            else
              [YAML.load_file(filename), false]
            end
          rescue TypeError, ScriptError, StandardError => e
            raise InvalidLocaleData.new(filename, e.inspect)
          end
        end
        alias_method :load_yaml, :load_yml

        # Loads a JSON translations file. The data must have locales as
        # toplevel keys.
        def load_json(filename)
          begin
            # Use #load_file as a proxy for a version of JSON where symbolize_names and freeze are supported.
            if ::JSON.respond_to?(:load_file)
              [::JSON.load_file(filename, symbolize_names: true, freeze: true), true]
            else
              [::JSON.parse(File.read(filename)), false]
            end
          rescue TypeError, StandardError => e
            raise InvalidLocaleData.new(filename, e.inspect)
          end
        end

        def translate_localization_format(locale, object, format, options)
          format.to_s.gsub(/%(|\^)[aAbBpP]/) do |match|
            case match
            when '%a' then I18n.t!(:"date.abbr_day_names",                  :locale => locale, :format => format)[object.wday]
            when '%^a' then I18n.t!(:"date.abbr_day_names",                 :locale => locale, :format => format)[object.wday].upcase
            when '%A' then I18n.t!(:"date.day_names",                       :locale => locale, :format => format)[object.wday]
            when '%^A' then I18n.t!(:"date.day_names",                      :locale => locale, :format => format)[object.wday].upcase
            when '%b' then I18n.t!(:"date.abbr_month_names",                :locale => locale, :format => format)[object.mon]
            when '%^b' then I18n.t!(:"date.abbr_month_names",               :locale => locale, :format => format)[object.mon].upcase
            when '%B' then I18n.t!(:"date.month_names",                     :locale => locale, :format => format)[object.mon]
            when '%^B' then I18n.t!(:"date.month_names",                    :locale => locale, :format => format)[object.mon].upcase
            when '%p' then I18n.t!(:"time.#{(object.respond_to?(:hour) ? object.hour : 0) < 12 ? :am : :pm}", :locale => locale, :format => format).upcase
            when '%P' then I18n.t!(:"time.#{(object.respond_to?(:hour) ? object.hour : 0) < 12 ? :am : :pm}", :locale => locale, :format => format).downcase
            end
          end
        rescue MissingTranslationData => e
          e.message
        end

        def pluralization_key(entry, count)
          key = :zero if count == 0 && entry.has_key?(:zero)
          key ||= count == 1 ? :one : :other
        end
    end
  end
end
