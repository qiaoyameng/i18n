# frozen_string_literal: true

require 'test_helper'

class I18nTraceTest < I18n::TestCase
  class SimpleBackend < I18n::Backend::Simple
    include I18n::Backend::Fallbacks
    include I18n::Backend::Pluralization
  end

  def setup
    super
    I18n.backend = SimpleBackend.new
    store_translations(:en, {
      plain: 'Plain text',
      interpolated: 'Hello %{name}',
      aliased: :plain,
      pluralized: { zero: 'none', one: 'one thing', other: '%{count} things' },
      stored_proc: ->(_object, **options) { "proc #{options[:name]}" },
      nested: { child: 'child value' },
      a_false: false,
      a_nil: nil,
      i18n: { plural: { rule: ->(n) { n == 0 ? :zero : n == 1 ? :one : :other } } }
    })
    I18n.fallbacks.map(:'de-DE' => [:de, :en])
    store_translations(:de, local: 'lokal', de_aliased: 'de alias')
  end

  def trace(key, **options)
    result, trace = I18n.translate_with_trace(key, **options)
    [result, trace]
  end

  test "returns the same translation as a plain translate call" do
    result, trace = trace(:plain)
    assert_equal 'Plain text', result
    assert_equal result, I18n.t(:plain)
    assert_equal 'Plain text', trace.final.result_value
  end

  test "root entry represents the top level call" do
    _result, trace = trace(:plain)
    root = trace.root
    assert root.root?
    assert_equal :translate, root.kind
    assert_equal :en, root.locale
    assert_equal :plain, root.key
    assert root.hit?
  end

  test "records every fallback locale that was tried" do
    _result, trace = trace(:plain, locale: :'de-DE')

    fallbacks = trace.entries.select { |entry| entry.kind == :fallback }
    assert_equal [:'de-DE', :de, :en], fallbacks.map(&:locale)
    assert_equal [0, 1, 2], fallbacks.map(&:fallback_index)
    assert_equal :'de-DE', fallbacks.first.original_locale
    assert_equal %i[missing missing hit], fallbacks.map(&:status)
  end

  test "the final entry points at the actual hit backend/locale/key" do
    _result, trace = trace(:plain, locale: :'de-DE')
    final = trace.final

    assert final.final?
    assert_equal :en, final.locale
    assert_equal :plain, final.key
    assert_equal :lookup, final.kind
    assert_includes final.backend.to_s, 'I18n::Backend::Simple'
    assert_equal final.location, trace.final.location
  end

  test "missing keys get a complete closed record" do
    result, trace = trace(:does_not_exist)
    assert_match(/Translation missing/, result)
    assert trace.root.missing?
    assert_nil trace.final
    assert trace.entries.all? { |entry| !entry.status.nil? }
    assert trace.misses.any?
  end

  test "missing translation with raise still closes the trace" do
    _result, trace = I18n.with_trace do
      assert_raises(I18n::MissingTranslationData) { I18n.t!(:does_not_exist) }
    end
    assert trace.root.missing?
    assert_equal I18n::MissingTranslationData, trace.root.result_class
  end

  test "false is recorded as a successful hit and stays false" do
    result, trace = trace(:a_false)
    assert_equal false, result
    assert_equal :false, trace.final.status
    assert trace.hit?
  end

  test "nil translation with default keeps existing nil semantics" do
    result, trace = trace(:a_nil, default: 'fallback text')
    assert_equal 'fallback text', result
    assert trace.hit?
    assert_equal :string, trace.final.default_type
  end

  test "default nil returns nil and records a nil status" do
    result, trace = trace(:does_not_exist, default: nil)
    assert_nil result
    assert_equal :nil, trace.root.status
    default_entry = trace.defaults.first
    assert_equal :nil, default_entry.status
  end

  test "symbol alias jumps are nested under the lookup" do
    store_translations(:de, aliased: :plain)
    _result, trace = trace(:aliased, locale: :'de-DE')
    alias_entry = trace.aliases.first

    assert alias_entry
    assert_equal :plain, alias_entry.alias_key
    assert alias_entry.hit?
    assert_operator alias_entry.depth, :>, 0
  end

  test "symbol aliases do not re-execute anything" do
    store_translations(:en, counter: 0)
    _result, trace = trace(:aliased)
    assert_equal 1, trace.entries.count { |entry| entry.kind == :alias }
  end

  test "proc translations are evaluated once and recorded" do
    calls = 0
    store_translations(:en, counted_proc: ->(_object, **) { calls += 1; 'done' })

    result, trace = trace(:counted_proc)
    assert_equal 'done', result
    assert_equal 1, calls
    assert_equal 1, trace.procs.size

    trace.send(:entries) # no evaluation just by inspecting
    trace.entries.map(&:status)
    assert_equal 1, calls
  end

  test "proc node does not retain the returned value" do
    result, trace = trace(:stored_proc, name: 'secret')
    assert_equal 'proc secret', result
    proc_entry = trace.procs.first
    assert_nil proc_entry.result_value
  end

  test "proc defaults are recorded as a default node with a proc child" do
    calls = 0
    proc_default = ->(_object, **) { calls += 1; 'from proc default' }

    result, trace = trace(:does_not_exist, default: [:missing_symbol, proc_default])
    assert_equal 'from proc default', result
    assert_equal 1, calls

    default_entry = trace.defaults.find { |entry| entry.default_type == :proc }
    assert default_entry
    proc_entry = trace.procs.find { |entry| entry.parent_id == default_entry.id }
    assert proc_entry
  end

  test "pluralization branch is recorded in the same call" do
    { 0 => :zero, 1 => :one, 3 => :other }.each do |count, branch|
      _result, trace = trace(:pluralized, count: count)
      plural = trace.pluralizations.first
      assert_equal branch, plural.plural_key
      assert_equal count, plural.count
    end
  end

  test "invalid pluralization data is recorded as an error" do
    store_translations(:en, broken_plural: { one: 'one' })
    _result, trace = I18n.with_trace do
      assert_raises(I18n::InvalidPluralizationData) { I18n.t(:broken_plural, count: 5) }
    end
    assert trace.root.error?
    assert_includes trace.errors.map(&:error_class), I18n::InvalidPluralizationData
  end

  test "nested translations form parent/child relationships" do
    _result, trace = trace(:'nested.child')
    final = trace.final

    assert_equal 'child value', _result
    assert_equal :lookup, final.kind
    assert_operator final.depth, :>=, 1
    lookup = trace.entries.find { |entry| entry.kind == :lookup && entry.key == :'nested.child' }
    assert lookup
  end

  test "fallback false skips fallback locales and is recorded" do
    result, trace = trace(:local, locale: :'de-DE', fallback: false)
    assert_match(/Translation missing/, result)
    locales = trace.entries.select { |entry| entry.kind == :lookup }.map(&:locale)
    assert_equal [:'de-DE'], locales
    assert trace.root.missing?
  end

  test "interpolation values are not stored in the trace" do
    _result, trace = trace(:interpolated, name: 'super-secret-value')
    serialized = trace.entries.map(&:to_h).inspect
    refute_includes serialized, 'super-secret-value'
  end

  test "capture_values false keeps result classes but not values" do
    _result, trace = I18n.translate_with_trace(:plain, capture_values: false)
    assert_equal String, trace.final.result_class
    assert_nil trace.final.result_value
  end

  test "bulk lookup records one bulk root with per-key children" do
    result, trace = trace([:plain, :aliased])
    assert_equal 2, result.size
    assert trace.root.bulk
    assert_operator trace.roots.size, :==, 1
    assert trace.entries.count { |entry| entry.kind == :translate } >= 2
  end

  test "untraced calls produce no trace" do
    assert_nil I18n::Trace.current
    I18n.t(:plain)
    assert_nil I18n::Trace.current
  end

  test "trace: false stays silent inside an active trace" do
    _result, trace = I18n.with_trace { I18n.t(:plain, trace: false) }
    assert_empty trace.entries
  end

  test "concurrent threads keep isolated traces" do
    observed = []
    threads = [:plain, :local].map do |key|
      Thread.new do
        result, trace = I18n.translate_with_trace(key, locale: :'de-DE')
        observed << [key, result, trace.entries.map(&:key)]
      end
    end
    threads.each(&:join)

    observed.each do |key, _result, keys|
      assert keys.all? { |traced_key| traced_key.nil? || traced_key == key || key == :local }
    end
  end

  test "nested I18n calls join the active trace" do
    store_translations(:en, outer: 'outer %{inner}')
    _result, trace = I18n.with_trace do
      I18n.t(:outer)
      I18n.t(:plain)
    end
    assert_equal 2, trace.roots.size
  end

  test "tree mirrors parent relationships" do
    _result, trace = trace(:aliased, locale: :'de-DE')
    tree_roots = trace.tree
    assert_equal 1, tree_roots.size
    assert tree_roots.first.children.any?
  end

  test "entries only describe lookups that really happened" do
    _result, trace = trace(:plain, locale: :'de-DE')
    locales = trace.attempts.map(&:locale)
    assert_equal [:'de-DE', :de, :en], locales.uniq
    # every fallback entry corresponds to a real backend lookup
    trace.entries.select { |entry| entry.kind == :fallback }.each do |fallback|
      assert trace.entries.any? { |entry| entry.kind == :lookup && entry.parent_id == fallback.id }
    end
  end
end

class I18nTraceChainTest < I18n::TestCase
  def setup
    super
    @primary = I18n::Backend::Simple.new
    @secondary = I18n::Backend::Simple.new
    I18n.backend = I18n::Backend::Chain.new(@primary, @secondary)
    @primary.store_translations(:en, shared: 'primary wins', primary_only: 'from primary')
    @secondary.store_translations(:en, shared: 'secondary loses', secondary_only: 'from secondary')
  end

  test "records each backend tried and keeps chain priority" do
    result, trace = I18n.translate_with_trace(:shared)
    assert_equal 'primary wins', result

    backends = trace.entries.select { |entry| entry.kind == :backend }
    assert_equal 1, backends.size
    assert_equal "I18n::Backend::Simple##{@primary.object_id}", backends.first.backend
  end

  test "falls through to the next backend without reordering" do
    result, trace = I18n.translate_with_trace(:secondary_only)
    assert_equal 'from secondary', result

    backend_entries = trace.entries.select { |entry| entry.kind == :backend }
    assert_equal [@primary.object_id, @secondary.object_id].map { |id| "I18n::Backend::Simple##{id}" },
                 backend_entries.map(&:backend)
    assert_equal @secondary.object_id, trace.final.backend.split('#').last.to_i
  end
end
