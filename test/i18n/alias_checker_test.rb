# frozen_string_literal: true

require 'test_helper'

class I18nAliasCheckerTest < I18n::TestCase
  class FallbackBackend < I18n::Backend::Simple
    include I18n::Backend::Fallbacks
  end

  def setup
    super
    I18n.backend = I18n::Backend::Simple.new
  end

  test "reports a clean namespace" do
    store_translations(:en, :foo => 'Foo', :bar => :foo)
    report = I18n.check_aliases(:en)
    assert_equal [], report.cycles
    assert_equal [], report.dangling
    assert_equal [], report.runtime
    assert report.clean?
  end

  test "detects a self-referencing alias" do
    store_translations(:en, :foo => :foo)
    report = I18n.check_aliases(:en)
    assert_equal 1, report.cycles.size
    assert_equal [['en:foo']], report.cycles.map(&:nodes)
    assert_equal [[['en:foo']]], report.cycles.map(&:entries)
    refute report.clean?
  end

  test "detects an indirect cycle and reports the full reference path" do
    store_translations(:en, :ns => { :a => :'ns.b', :b => :'ns.c', :c => :'ns.a' })
    report = I18n.check_aliases(:en, :scope => :ns)
    assert_equal 1, report.cycles.size
    cycle = report.cycles.first
    assert_equal %w[en:ns.a en:ns.b en:ns.c], cycle.nodes
    assert_equal [%w[en:ns.a]], cycle.entries
  end

  test "reports a shared cycle only once but lists every entry" do
    store_translations(:en, :one => :'loop.a', :two => :'loop.a',
      :loop => { :a => :'loop.b', :b => :'loop.a' })
    report = I18n.check_aliases(:en)
    assert_equal 1, report.cycles.size
    cycle = report.cycles.first
    assert_equal %w[en:loop.a en:loop.b], cycle.nodes
    assert_equal [
      %w[en:one en:loop.a],
      %w[en:two en:loop.a],
      %w[en:loop.a]
    ].sort, cycle.entries.sort
  end

  test "does not mistake a legal diamond dependency for a cycle" do
    store_translations(:en, :a => :shared, :b => :shared, :shared => :target, :target => 'text')
    report = I18n.check_aliases(:en)
    assert_equal [], report.cycles
    assert report.clean?
  end

  test "reports dangling alias targets with the full path" do
    store_translations(:en, :ns => { :a => :'ns.b', :b => :missing })
    report = I18n.check_aliases(:en, :scope => :ns)
    assert_equal [], report.cycles
    assert_equal 1, report.dangling.size
    dangling = report.dangling.first
    assert_equal %w[en:ns.a en:ns.b], dangling.path
    assert_equal 'en:missing', dangling.target
    refute report.clean?
  end

  test "reports Procs as runtime decided without calling them" do
    called = false
    store_translations(:en, :foo => lambda { |_key, **_options| called = true; 'Foo' })
    report = I18n.check_aliases(:en)
    assert_equal false, called
    assert_equal [], report.cycles
    assert_equal [%w[en:foo]], report.runtime.map(&:path)
    refute report.clean?
  end

  test "reports Procs referenced by aliases without calling them" do
    called = false
    store_translations(:en, :foo => :bar, :bar => lambda { |_key, **_options| called = true; 'Bar' })
    report = I18n.check_aliases(:en)
    assert_equal false, called
    assert_equal [%w[en:bar]], report.runtime.map(&:path)
  end

  test "respects the scope option" do
    store_translations(:en, :checked => { :a => :'checked.b', :b => :'checked.a' },
      :unchecked => { :a => :'unchecked.a' })
    report = I18n.check_aliases(:en, :scope => :checked)
    assert_equal 1, report.cycles.size
    assert_equal %w[en:checked.a en:checked.b], report.cycles.first.nodes
  end

  test "respects a custom separator" do
    store_translations(:en, :ns => { :a => :'ns/b', :b => :'ns/a' })
    report = I18n.check_aliases(:en, :scope => 'ns', :separator => '/')
    assert_equal 1, report.cycles.size
    assert_equal %w[en:ns/a en:ns/b], report.cycles.first.nodes
  end

  test "does not merge same-named keys from different namespaces" do
    store_translations(:en, :one => { :target => :'two.target' }, :two => { :target => 'text' })
    report = I18n.check_aliases(:en)
    assert_equal [], report.cycles
    assert_equal [], report.dangling
    assert report.clean?
  end

  test "detects cycles spanning locales through fallbacks" do
    I18n.backend = FallbackBackend.new
    I18n.fallbacks = I18n::Locale::Fallbacks.new(:en)
    store_translations(:de, :foo => :bar)
    store_translations(:en, :bar => :foo)
    report = I18n.check_aliases(:de)
    assert_equal 1, report.cycles.size
    cycle = report.cycles.first
    assert_equal %w[de:foo en:bar], cycle.nodes
    assert_equal [%w[de:foo]], cycle.entries
  end

  test "resolves alias targets through locale fallbacks" do
    I18n.backend = FallbackBackend.new
    I18n.fallbacks = I18n::Locale::Fallbacks.new(:en)
    store_translations(:de, :foo => :bar)
    store_translations(:en, :bar => 'Bar in :en')
    report = I18n.check_aliases(:de)
    assert_equal [], report.cycles
    assert_equal [], report.dangling
    assert report.clean?
  end

  test "reports targets missing from the whole fallback chain as dangling" do
    I18n.backend = FallbackBackend.new
    I18n.fallbacks = I18n::Locale::Fallbacks.new(:en)
    store_translations(:de, :foo => :missing)
    store_translations(:en, :bar => 'Bar in :en')
    report = I18n.check_aliases(:de)
    assert_equal 1, report.dangling.size
    assert_equal 'de:missing', report.dangling.first.target
  end

  test "does not modify the stored translations" do
    store_translations(:en, :foo => :bar, :bar => :foo, :baz => 'Baz')
    before = I18n.backend.send(:translations)[:en].inspect
    I18n.check_aliases(:en)
    assert_equal before, I18n.backend.send(:translations)[:en].inspect
    assert_equal 'Baz', I18n.t(:baz, :locale => :en)
  end

  test "returns a report for an empty or missing namespace" do
    store_translations(:en, :foo => 'Foo')
    report = I18n.check_aliases(:en, :scope => :missing)
    assert_equal [], report.cycles
    assert_equal [], report.dangling
    assert report.clean?
  end

  test "defaults to the current locale" do
    I18n.locale = :en
    store_translations(:en, :foo => :foo)
    report = I18n.check_aliases
    assert_equal 1, report.cycles.size
  end
end
