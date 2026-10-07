# frozen_string_literal: true

module I18n
  module Backend
    # Sentinel value that explicitly masks ("blocks") a translation.
    #
    # Storing this value for a key (or a whole namespace) marks the lookup as
    # definitively missing: neither a Chain backend nor locale Fallbacks will
    # continue searching in lower backends or other fallback locales. This is
    # useful when an overlay (e.g. tenant-specific translations) needs to take
    # an outdated common translation completely offline instead of overriding
    # it with new text - simply deleting the key would let the underlying
    # translation show through again.
    #
    #   I18n.backend.store_translations(:en, :obsolete => I18n::Backend::MASKED)
    #   I18n.backend.store_translations(:en, :legacy_namespace => I18n::Backend::MASKED)
    #
    # A masked lookup behaves like a missing translation: it raises
    # I18n::MissingTranslationData with :raise => true and still honors a
    # non-symbol :default passed by the caller. The values nil, false and ""
    # keep their original semantics and can not be used as a mask.
    #
    # To unmask a key simply store a new value (or nil) over the mask, which
    # restores translations from lower backends / fallback locales.
    MASKED = Object.new

    def MASKED.inspect
      'I18n::Backend::MASKED'
    end

    def MASKED.to_s
      'I18n::Backend::MASKED'
    end

    MASKED.freeze
  end
end
