# Ruby I18n

[![Gem Version](https://badge.fury.io/rb/i18n.svg)](https://badge.fury.io/rb/i18n)
[![Build Status](https://github.com/ruby-i18n/i18n/workflows/Ruby/badge.svg)](https://github.com/ruby-i18n/i18n/actions?query=workflow%3ARuby)

Ruby internationalization and localization (i18n) solution.

Currently maintained by @radar.

## Usage

### Rails

You will most commonly use this library within a Rails app.

We support Rails versions from 6.0 and up.

[See the Rails Guide](https://guides.rubyonrails.org/i18n.html) for an example of its usage.

### Ruby (without Rails)

We support Ruby versions from 3.1 and up.

If you want to use this library without Rails, you can simply add `i18n` to your `Gemfile`:

```ruby
gem 'i18n'
```

Then configure I18n with some translations, and a default locale:

```ruby
I18n.load_path += Dir[File.expand_path("config/locales") + "/*.yml"]
I18n.default_locale = :en # (note that `en` is already the default!)
```

A simple translation file in your project might live at `config/locales/en.yml` and look like:

```yml
en:
  test: "This is a test"
```

You can then access this translation by doing:

```ruby
I18n.t(:test)
```

You can switch locales in your project by setting `I18n.locale` to a different value:

```ruby
I18n.locale = :de
I18n.t(:test) # => "Dies ist ein Test"
```

### Fiber-safe config updates

`Fiber[]` values are inherited by child fibers.
To avoid sharing mutable config objects across fibers, prefer creating updated configs and setting them with `set!`:

```ruby
I18n.config.with(locale: :ja).set!
```

`set!` stores a frozen config in the current execution context.
This keeps inherited state safe and lets updates happen by replacing config objects.

## Features

* Translation and localization
* Interpolation of values to translations
* Pluralization (CLDR compatible)
* Customizable transliteration to ASCII
* Flexible defaults
* Bulk lookup
* Lambdas as translation data
* Custom key/scope separator
* Custom exception handlers
* Extensible architecture with a swappable backend

## Blocking translations

Sometimes a tenant translation needs to permanently retire a copy that the
base application (or a fallback locale) still ships. Deleting the overriding
key is not enough with `I18n::Backend::Chain`, because the chain then falls
through to the lower backend and surfaces the old copy again.

Store the `I18n::BLOCKED` sentinel on the leaf key (or on an entire
namespace) to mark the lookup as terminally missing. The block affects both
`translate` and `exists?`, stops the `Chain` from consulting lower backends
and stops `I18n::Backend::Fallbacks` from trying other locales. The marker
never appears in returned values: blocked hash keys are simply omitted.

```ruby
I18n.backend.store_translations(:en, retired_button: I18n::BLOCKED,
                                old_section: { hint: I18n::BLOCKED })

I18n.t(:retired_button)        # => "Translation blocked: en.retired_button"
I18n.exists?(:retired_button)  # => false
I18n.t(:old_section)           # => {} (the blocked leaf is omitted)
```

`nil`, `false` and the empty String keep their original meaning and must not
be used as markers. An explicit, non-Symbol `:default` passed by the caller
is still honored, as usual; a Symbol default that itself resolves to a
blocked key stays blocked.

```ruby
I18n.t(:retired_button, default: "Not available") # => "Not available"
I18n.t(:retired_button, default: nil)             # => nil
I18n.t(:other, default: :retired_button)          # => "Translation blocked: ..."
```

Removing the entry (e.g. reloading translations without the marker)
unblocks the key again, so lower backend / fallback translations become
visible:

```ruby
I18n.backend = I18n::Backend::Chain.new(tenant_backend, app_backend)
tenant_backend.store_translations(:en, :shared => I18n::BLOCKED)
I18n.t(:shared) # => "Translation blocked: en.shared"

tenant_backend.send(:translations)[:en].delete(:shared)
I18n.t(:shared) # => the copy from app_backend is back
```

## Pluggable Features

* Cache
* Pluralization: lambda pluralizers stored as translation data
* Locale fallbacks, RFC4647 compliant (optionally: RFC4646 locale validation)
* [Gettext support](https://github.com/ruby-i18n/i18n/wiki/Gettext)
* Translation metadata

## Alternative Backend

* Chain
* ActiveRecord (optionally: ActiveRecord::Missing and ActiveRecord::StoreProcs)
* KeyValue (uses active_support/json and cannot store procs)

For more information and lots of resources see [the 'Resources' page on the wiki](https://github.com/ruby-i18n/i18n/wiki/Resources).

## Tests

You can run tests both with

* `rake test` or just `rake`
* run any test file directly, e.g. `ruby -Ilib:test test/api/simple_test.rb`

You can run all tests against all Gemfiles with

* `ruby test/run_all.rb`

The structure of the test suite is a bit unusual as it uses modules to reuse
particular tests in different test cases.

The reason for this is that we need to enforce the I18n API across various
combinations of extensions. E.g. the Simple backend alone needs to support
the same API as any combination of feature and/or optimization modules included
to the Simple backend. We test this by reusing the same API definition (implemented
as test methods) in test cases with different setups.

You can find the test cases that enforce the API in test/api. And you can find
the API definition test methods in test/api/tests.

All other test cases (e.g. as defined in test/backend, test/core_ext) etc.
follow the usual test setup and should be easy to grok.

## More Documentation

Additional documentation can be found here: https://github.com/ruby-i18n/i18n/wiki

## Contributors

* @radar
* @carlosantoniodasilva
* @josevalim
* @knapo
* @tigrish
* [and many more](https://github.com/ruby-i18n/i18n/graphs/contributors)

## License

MIT License. See the included MIT-LICENSE file.
