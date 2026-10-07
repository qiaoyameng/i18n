# frozen_string_literal: true

# I18n locale fallbacks are useful when you want your application to use
# translations from other locales when translations for the current locale are
# missing. E.g. you might want to use :en translations when translations in
# your applications main locale :de are missing.
#
# To enable locale fallbacks you can simply include the Fallbacks module to
# the Simple backend - or whatever other backend you are using:
#
#   I18n::Backend::Simple.include(I18n::Backend::Fallbacks)
module I18n
  @@fallbacks = nil

  class << self
    # Returns the current fallbacks implementation. Defaults to +I18n::Locale::Fallbacks+.
    def fallbacks
      @@fallbacks ||= I18n::Locale::Fallbacks.new
      if Fiber.respond_to?(:[])
        Fiber[:i18n_fallbacks] || @@fallbacks
      else
        Thread.current[:i18n_fallbacks] || @@fallbacks
      end
    end

    # Sets the current fallbacks implementation. Use this to set a different fallbacks implementation.
    def fallbacks=(fallbacks)
      @@fallbacks = fallbacks.is_a?(Array) ? I18n::Locale::Fallbacks.new(fallbacks) : fallbacks
      if Fiber.respond_to?(:[])
        Fiber[:i18n_fallbacks] = @@fallbacks
      else
        Thread.current[:i18n_fallbacks] = @@fallbacks
      end
    end
  end

  module Backend
    module Fallbacks
      # Overwrites the Base backend translate method so that it will try each
      # locale given by I18n.fallbacks for the given locale. E.g. for the
      # locale :"de-DE" it might try the locales :"de-DE", :de and :en
      # (depends on the fallbacks implementation) until it finds a result with
      # the given options. If it does not find any result for any of the
      # locales it will then throw MissingTranslation as usual.
      #
      # The default option takes precedence over fallback locales only when
      # it's a Symbol. When the default contains a String, Proc or Hash
      # it is evaluated last after all the fallback locales have been tried.
      def translate(locale, key, options = EMPTY_HASH)
        return super unless options.fetch(:fallback, true)
        return super if options[:fallback_in_progress]
        default = extract_non_symbol_default!(options) if options[:default]

        fallback_options = options.merge(:fallback_in_progress => true, fallback_original_locale: locale)
        tracer = I18n::Trace.current
        I18n.fallbacks[locale].each_with_index do |fallback, fallback_index|
          begin
            if tracer
              attributes = {
                backend: I18n::Trace.backend_name(self),
                locale: fallback,
                original_locale: locale,
                key: key,
                scope: options[:scope],
                fallback_index: fallback_index
              }
              catch(:exception) do
                result = tracer.wrap(:fallback, attributes) do
                  fallback_super_translate(fallback, key, fallback_options)
                end
                unless result.nil?
                  on_fallback(locale, fallback, key, options) if locale.to_s != fallback.to_s
                  return result
                end
              end
            else
              catch(:exception) do
                result = super(fallback, key, fallback_options)
                unless result.nil?
                  on_fallback(locale, fallback, key, options) if locale.to_s != fallback.to_s
                  return result
                end
              end
            end
          rescue I18n::InvalidLocale
            # we do nothing when the locale is invalid, as this is a fallback anyways.
          end
        end

        return if options.key?(:default) && options[:default].nil?

        return super(locale, nil, options.merge(:default => default)) if default
        throw(:exception, I18n::MissingTranslation.new(locale, key, options))
      end

      # Resolves the +translate+ implementation above Fallbacks at runtime so
      # tracing wrappers do not have to thread +super+ through nested blocks.
      def fallback_super_translate(locale, key, options)
        method(:translate).super_method.call(locale, key, options)
      end

      def resolve_entry(locale, object, subject, options = EMPTY_HASH)
        return subject if options[:resolve] == false
        result = catch(:exception) do
          options.delete(:fallback_in_progress) if options.key?(:fallback_in_progress)

          case subject
          when Symbol
            tracer = I18n::Trace.current
            translation = -> {
              I18n.translate(subject, **options.merge(
                :locale => options[:fallback_original_locale],
                :throw => true,
                :skip_interpolation => true
              ))
            }
            if tracer
              tracer.wrap(:alias, {
                locale: options[:fallback_original_locale],
                key: subject,
                alias_key: subject,
                scope: options[:scope]
              }) { translation.call }
            else
              translation.call
            end
          when Proc
            date_or_time = options.delete(:object) || object
            tracer = I18n::Trace.current
            called = if tracer
              tracer.wrap(:proc, locale: options[:fallback_original_locale], key: object, capture: false) do
                subject.call(date_or_time, **options)
              end
            else
              subject.call(date_or_time, **options)
            end
            resolve_entry(options[:fallback_original_locale], object, called)
          else
            subject
          end
        end
        result unless result.is_a?(MissingTranslation)
      end

      def extract_non_symbol_default!(options)
        defaults = [options[:default]].flatten
        first_non_symbol_default = defaults.detect{|default| !default.is_a?(Symbol)}
        if first_non_symbol_default
          options[:default] = defaults[0, defaults.index(first_non_symbol_default)]
        end
        return first_non_symbol_default
      end

      def exists?(locale, key, options = EMPTY_HASH)
        return super unless options.fetch(:fallback, true)
        I18n.fallbacks[locale].each do |fallback|
          begin
            return true if super(fallback, key, options)
          rescue I18n::InvalidLocale
            # we do nothing when the locale is invalid, as this is a fallback anyways.
          end
        end

        false
      end

      private

        # Overwrite on_fallback to add specified logic when the fallback succeeds.
        def on_fallback(_original_locale, _fallback_locale, _key, _options)
          nil
        end
    end
  end
end
