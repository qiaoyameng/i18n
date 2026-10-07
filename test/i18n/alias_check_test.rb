# frozen_string_literal: true

require 'test_helper'

class I18nAliasCheckTest < I18n::TestCase
  def setup
    super
    I18n.backend = I18n::Backend::Simple.new
  end

  test "reports a static alias cycle once with every entry into the cycle" do
    store_translations(:en, :a => :b, :entry => :a, :b => :entry)

    result = I18n.check_aliases(:en)

    assert_equal 1, result[:cycles].size
    assert_equal [:a, :b, :entry, :a], result[:cycles].first[:cycle].map(&:last)
    entries = result[:cycles].first[:entries].map { |path| path.map(&:last) }
    assert_includes entries, %i[a b entry a]
    assert_includes entries, %i[b entry a b]
    assert_includes entries, %i[entry a b entry]
  end

  test "reports dangling aliases with the complete reference path" do
    store_translations(:en, :entry => :missing, :other => :entry)

    result = I18n.check_aliases(:en)

    paths = result[:dangling].flat_map { |issue| issue[:paths] }.map { |path| path.map(&:last) }
    assert_includes paths, [:entry, :missing]
    assert_includes paths, [:other, :entry, :missing]
    assert_equal [:missing], result[:dangling].map { |issue| issue[:target].last }
  end

  test "treats repeated access to a shared destination as a diamond, not a cycle" do
    store_translations(:en, :left => :shared, :right => :shared, :shared => 'value')

    assert_empty I18n.check_aliases(:en)[:cycles]
    assert_empty I18n.check_aliases(:en)[:dangling]
  end

  test "respects scopes, separators, and keeps equal names in different namespaces separate" do
    store_translations(:en,
      :users => { :link => :missing },
      :posts => { :link => :"posts.present", :present => 'value' },
      :pipes => { :"a|b" => :"pipes|missing" }
    )

    users = I18n.check_aliases(:en, :users)
    scoped_users = I18n.check_aliases(:en, :scope => :users)
    posts = I18n.check_aliases(:en, :posts)
    pipes = I18n.check_aliases(:en, :pipes, :separator => '|')

    assert_equal [:"users.link", :missing], users[:dangling].first[:paths].first.map(&:last)
    assert_equal(
      users[:dangling].first[:paths].first,
      scoped_users[:dangling].first[:paths].first
    )
    assert_empty posts[:dangling]
    assert_equal [:"pipes|a|b", :"pipes|missing"], pipes[:dangling].first[:paths].first.map(&:last)
  end

  test "follows namespace aliases to their expanded suffix entries" do
    store_translations(:en,
      :src => :"target.tree",
      :target => { :tree => { :leaf => :"src.leaf" } }
    )

    result = I18n.check_aliases(:en)

    assert_equal [:src, :"target.tree", :"target.tree.leaf", :"src.leaf", :src],
      result[:cycles].first[:cycle].map(&:last)
    assert_includes result[:cycles].first[:entries].map { |path| path.map(&:last) },
      [:"src.leaf", :src, :"target.tree", :"target.tree.leaf", :"src.leaf"]
  end

  test "reports proc values as runtime decisions without invoking them" do
    invoked = false
    store_translations(:en, :runtime => proc { invoked = true }, :alias => :runtime)

    result = I18n.check_aliases(:en)

    assert_equal [:runtime], result[:runtime_decisions].map { |issue| issue[:key].last }
    paths = result[:runtime_decisions].first[:paths].map { |path| path.map(&:last) }
    assert_includes paths, [:alias, :runtime]
    refute invoked
  end

  test "does not populate memoized lookup entries or mutate stored aliases" do
    backend = Class.new(I18n::Backend::Simple) { include I18n::Backend::Memoize }.new
    I18n.backend = backend
    store_translations(:en, :my_alias => :value, :value => 'original')

    I18n.check_aliases(:en)

    assert_equal :value, backend.instance_variable_get(:@translations)[:en][:my_alias]
    assert_equal 0, backend.send(:memoized_lookup)[:en].size
  end
end

class I18nFallbackAliasCheckTest < I18n::TestCase
  class Backend < I18n::Backend::Simple
    include I18n::Backend::Fallbacks
  end

  def setup
    super
    I18n.backend = Backend.new
    I18n.fallbacks = [:'en-US', :en, :root]
  end

  test "detects cycles that cross locale fallback boundaries" do
    store_translations(:'en-US', :a => :root_a)
    store_translations(:root, :root_a => :a)

    result = I18n.check_aliases(:'en-US')

    assert_equal [
      [:'en-US', :a],
      [:'en-US', :root_a],
      [:root, :root_a],
      [:'en-US', :a]
    ], result[:cycles].first[:cycle]
  end

  test "restarts symbol resolution at the original locale during fallback" do
    store_translations(:ak,
      :calendars => { :gregorian => { :months => {
        :format => { :abbreviated => { 1 => 'S-Ɔ' } }
      } } }
    )
    store_translations(:root,
      :calendars => { :gregorian => { :months => {
        :format => {
          :abbreviated => :"calendars.gregorian.months.format.wide",
          :wide => { 1 => 'M01' }
        },
        :'stand-alone' => { :abbreviated => :"calendars.gregorian.months.format.abbreviated" }
      } } }
    )

    result = I18n.check_aliases(:'ak-GH')

    assert_empty result[:cycles]
    assert_empty result[:dangling]
  end

  test "can disable locale fallback" do
    store_translations(:en, :a => :b, :b => 'value')

    assert_empty I18n.check_aliases(:de, :fallback => false)[:cycles]
  end
end
